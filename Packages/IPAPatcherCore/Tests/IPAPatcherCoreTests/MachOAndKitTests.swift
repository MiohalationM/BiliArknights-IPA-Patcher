import Foundation
import XCTest
@testable import IPAPatcherCore

final class MachOAndKitTests: XCTestCase {
    func testMachOParserThinAndFatAndEncryption() throws {
        let uuid = "c0c6e046-81ae-3987-817a-0f1530ab074f"
        let decrypted = SyntheticIPABuilder.makeThinMachO64(uuidString: uuid, cryptid: 0)
        let decryptedSlices = try MachOParser.parseSlices(data: decrypted, binaryPath: "Arknights", includeSHA256: true)
        XCTAssertEqual(decryptedSlices.count, 1)
        XCTAssertEqual(decryptedSlices[0].cpuType, MachOSliceInfo.cpuTypeARM64)
        XCTAssertEqual(decryptedSlices[0].architectureName, "arm64")
        XCTAssertEqual(decryptedSlices[0].uuid, uuid)
        XCTAssertEqual(decryptedSlices[0].cryptids, [0])
        XCTAssertFalse(decryptedSlices[0].isEncrypted)
        XCTAssertNotNil(decryptedSlices[0].sha256)

        let encrypted = SyntheticIPABuilder.makeThinMachO64(uuidString: uuid, cryptid: 1)
        let encryptedSlices = try MachOParser.parseSlices(data: encrypted, binaryPath: "Arknights")
        XCTAssertTrue(encryptedSlices[0].isEncrypted)
        XCTAssertEqual(encryptedSlices[0].cryptids, [1])

        let fat = SyntheticIPABuilder.makeFat32(slices: [
            (MachOSliceInfo.cpuTypeARM64, decrypted),
            (MachOSliceInfo.cpuTypeX86_64, SyntheticIPABuilder.makeThinMachO64(uuidString: uuid, cpuType: MachOSliceInfo.cpuTypeX86_64))
        ])
        let fatSlices = try MachOParser.parseSlices(data: fat, binaryPath: "FatBin")
        XCTAssertEqual(fatSlices.count, 2)
        XCTAssertEqual(fatSlices.map(\.architectureName), ["arm64", "x86_64"])

        XCTAssertThrowsError(try MachOParser.parseSlices(data: Data([0x01, 0x02, 0x03]), binaryPath: "Tiny"))
    }

    func testDynamicMachOInjectorMatchesBaselineAndBlocksDuplicateInjection() throws {
        let unity = SyntheticIPABuilder.makeThinMachO64(
            uuidString: "386e1e29-f538-38c5-84d3-40427d3e6eb1",
            targetNcmds: 0x61,
            targetSizeOfCmds: 0x2ad8,
            trailingZeroBytes: 4096
        )
        let dylibPath = "@executable_path/Frameworks/ABLoginBridge.dylib"
        let (injected, report) = try MachODylibInjector.inject(
            dylibLoadPath: dylibPath,
            into: unity,
            binaryPath: "UnityFramework"
        )

        // Must match exact baseline 2.7.91 offsets & bytes without hardcoding!
        XCTAssertEqual(report.insertOffset, 11000)
        XCTAssertEqual(report.commandSize, 72)
        XCTAssertEqual(report.previousLoadCommandCount, 0x61)
        XCTAssertEqual(report.newLoadCommandCount, 0x62)
        XCTAssertEqual(injected[16..<24], try BinaryRangePatcher.decodeHex("62000000202b0000", binaryPath: "UnityFramework", offset: 16))
        XCTAssertEqual(
            injected[11000..<11072],
            try BinaryRangePatcher.decodeHex(
                "0c00000048000000180000000000000000000100000001004065786563757461626c655f706174682f4672616d65776f726b732f41424c6f67696e4272696467652e64796c696200",
                binaryPath: "UnityFramework",
                offset: 11000
            )
        )

        // Second injection must be cleanly rejected as alreadyInjected.
        XCTAssertThrowsError(
            try MachODylibInjector.inject(dylibLoadPath: dylibPath, into: injected, binaryPath: "UnityFramework")
        ) { error in
            guard case PatchError.alreadyInjected = error else {
                return XCTFail("Expected alreadyInjected, got \(error)")
            }
        }
    }

    func testDynamicHostInfoPlistPatcherPreservesHostKeys() throws {
        let hostPlist: [String: Any] = [
            "CFBundleIdentifier": "com.hypergryph.arknights",
            "CFBundleShortVersionString": "2.8.99",
            "CFBundleVersion": "99",
            "CFBundleExecutable": "Arknights",
            "CustomFutureKey": "keep-me",
            "U8SDK": [
                "AppId": 1,
                "AppKey": "e965bb316534227f7fa8024fe3dc9539",
                "Channel": 1,
                "World": 1,
                "ChannelName": "HG",
                "Plugins": [["className": "HGN"]]
            ]
        ]
        let raw = try PropertyListSerialization.data(fromPropertyList: hostPlist, format: .binary, options: 0)
        let patchedData = try HostInfoPlistPatcher.patch(
            hostInfoPlistData: raw,
            revision: "test-rev",
            expectedBundleID: "com.hypergryph.arknights"
        )
        let obj = try PropertyListSerialization.propertyList(from: patchedData, options: [], format: nil)
        let dict = try XCTUnwrap(obj as? [String: Any])

        XCTAssertEqual(dict["CFBundleShortVersionString"] as? String, "2.8.99")
        XCTAssertEqual(dict["CFBundleVersion"] as? String, "99")
        XCTAssertEqual(dict["CustomFutureKey"] as? String, "keep-me")
        XCTAssertEqual(dict["ABPackagingRevision"] as? String, "test-rev")
        XCTAssertNotNil(dict["NSUserTrackingUsageDescription"] as? String)

        let u8 = try XCTUnwrap(dict["U8SDK"] as? [String: Any])
        XCTAssertEqual(u8["Channel"] as? Int, 2)
        XCTAssertEqual(u8["World"] as? Int, 2)
        XCTAssertEqual(u8["AppKey"] as? String, "ea3e65c0259e6ae1a6eabca899fcb6b0")
        XCTAssertEqual(u8["ChannelName"] as? String, "HG")
        XCTAssertNotNil(u8["Plugins"])

        let schemes = try XCTUnwrap(dict["LSApplicationQueriesSchemes"] as? [String])
        XCTAssertTrue(schemes.contains("bilibili"))
        XCTAssertTrue(schemes.contains("bilibili.following"))
    }

    func testBuiltInCarrierKitIntegrityVerification() throws {
        let engine = try IPAPatcherEngine.builtInDefault()
        let kits = try engine.verifyConfiguredKits()
        XCTAssertEqual(kits.count, 1)
        let kit = kits[0]
        XCTAssertEqual(kit.manifestSHA256, BuiltInKitRepository.lockedManifestSHA256)
        XCTAssertEqual(kit.manifest.revision, "7.5-2.7.91-bridge-carrier-r4")
        XCTAssertEqual(kit.manifest.version, "2.7.91")
        XCTAssertEqual(kit.manifest.build, "76")
        XCTAssertEqual(kit.payloadEntryCount, 206)
        XCTAssertEqual(kit.manifest.hostBinaries.count, 6)
        XCTAssertNotNil(kit.manifest.payloadEntries["Payload/Arknights.app/Frameworks/ABLoginBridge.dylib"])
        XCTAssertNotNil(kit.manifest.payloadEntries["Payload/Arknights.app/Frameworks/ABSDKCarrier.dylib"])
        XCTAssertNotNil(kit.manifest.payloadEntries["Payload/Arknights.app/ABRuntimeProfile.plist"])
    }

    func testHostInspectorProbeAndMatcherDetectsAllMismatches() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let engine = try IPAPatcherEngine.builtInDefault()
        let kits = try engine.verifyConfiguredKits()
        let manifest = kits[0].manifest

        // 1. Exact matching IPA + IL2CPP metadata probe
        let matchingIPA = tempDir.appendingPathComponent("matching.ipa")
        try SyntheticIPABuilder.createSyntheticIPA(at: matchingIPA, manifest: manifest)
        let host = try engine.inspectHost(at: matchingIPA)
        XCTAssertEqual(host.bundleID, "com.hypergryph.arknights")
        XCTAssertEqual(host.version, "2.7.91")
        XCTAssertEqual(host.build, "76")
        XCTAssertFalse(host.isEncrypted)
        XCTAssertEqual(host.binaries.count, 6)
        XCTAssertEqual(host.il2cppProbe?.hasGlobalMetadata, true)
        XCTAssertEqual(host.il2cppProbe?.globalMetadataIsPlaintext, true)
        XCTAssertEqual(host.il2cppProbe?.globalMetadataVersion, 29)
        XCTAssertEqual(host.il2cppProbe?.detectedInjectedBridge, false)

        let matchResult = try engine.matchCompatibility(for: host, verifiedKits: kits)
        guard case .matched(let config) = matchResult else {
            return XCTFail("Expected exact match")
        }
        XCTAssertEqual(config.manifest.revision, "7.5-2.7.91-bridge-carrier-r4")

        // 2. Incompatible IPA with multiple mismatches simultaneously
        var badConfig = SyntheticIPABuilder.Configuration()
        badConfig.version = "2.8.01"
        badConfig.build = "88"
        badConfig.encryptMainBinary = true
        badConfig.overrideUnityUUID = "11111111-2222-3333-4444-555555555555"

        let badIPA = tempDir.appendingPathComponent("mismatch.ipa")
        try SyntheticIPABuilder.createSyntheticIPA(at: badIPA, manifest: manifest, config: badConfig)
        let badHost = try engine.inspectHost(at: badIPA)
        let badMatch = try engine.matchCompatibility(for: badHost, verifiedKits: kits)

        guard case .incompatible(let report) = badMatch else {
            return XCTFail("Expected incompatibility report")
        }
        XCTAssertEqual(report.actualVersion, "2.8.01")
        XCTAssertEqual(report.actualBuild, "88")
        XCTAssertTrue(report.isEncrypted)
        let kinds = Set(report.mismatches.map(\.kind))
        XCTAssertTrue(kinds.contains(.encryptedBinary))
        XCTAssertTrue(kinds.contains(.version))
        XCTAssertTrue(kinds.contains(.build))
        XCTAssertTrue(kinds.contains(.binaryUUID))
    }
}
