import Foundation
import XCTest
@testable import IPAPatcherCore
import Zip64Kit

final class IL2CPPAndOptionsTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IL2CPPAndOptionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testRuntimeOffsetProfileParsesJSONAndPlistAndEmitsBinaryPlist() throws {
        // 1. Parse human-authored JSON template with 0x hex strings.
        let jsonData = Data(RuntimeOffsetProfile.sampleJSONTemplate.utf8)
        let decodedFromJSON = try RuntimeOffsetProfile.decode(from: jsonData)
        XCTAssertEqual(decodedFromJSON.version, "2.7.91")
        XCTAssertEqual(decodedFromJSON.build, "76")
        XCTAssertEqual(decodedFromJSON.unityUUID, "386e1e29-f538-38c5-84d3-40427d3e6eb1")
        XCTAssertEqual(decodedFromJSON.il2cppOffsets, IL2CPPOffsetSet.builtIn2791)

        // 2. Emit binary `ABRuntimeProfile.plist` and re-decode from plist directly!
        let plistData = try decodedFromJSON.encodeToRuntimeProfilePlistData()
        let decodedFromPlist = try RuntimeOffsetProfile.decode(from: plistData)
        XCTAssertEqual(decodedFromPlist.version, "2.7.91")
        XCTAssertEqual(decodedFromPlist.build, "76")
        XCTAssertEqual(decodedFromPlist.unityUUID, decodedFromJSON.unityUUID)
        XCTAssertEqual(decodedFromPlist.il2cppOffsets, IL2CPPOffsetSet.builtIn2791)
        XCTAssertEqual(decodedFromPlist.unityTextSize, 0x099f_7a28)

        // 3. Reject invalid UUID or half-specified __text digest.
        let badJSON = Data("""
        {
          "schema": 1,
          "version": "2.8.0",
          "build": "80",
          "unityUUID": "not-a-valid-uuid",
          "il2cppOffsets": {
            "sdkInterfaceClassSlot": "0x1000",
            "sdkExternalToolsClassSlot": "0x1008",
            "sdkMetaClassSlot": "0x1010",
            "networkerTypeSlot": "0x1018",
            "gameFlowClassSlot": "0x1020",
            "getNetworkConfigFn": "0x2000",
            "overrideNetworkOptionsFn": "0x2010",
            "createStringFn": "0x2020",
            "internalSDKMetaFn": "0x2030",
            "sdkMetaCtorFn": "0x2040",
            "clearAuthStatusFn": "0x2050",
            "clearLoginStatusFn": "0x2060",
            "getCurrentSceneFn": "0x2070"
          }
        }
        """.utf8)
        XCTAssertThrowsError(try RuntimeOffsetProfile.decode(from: badJSON))

        let halfDigestProfile = RuntimeOffsetProfile(
            name: "半残指纹",
            revision: "test-half",
            version: "2.8.0",
            build: "80",
            unityUUID: "11223344-5566-7788-99aa-bbccddeeff00",
            unityTextSize: 0x1000,
            unityTextSHA256: nil,
            il2cppOffsets: .builtIn2791
        )
        XCTAssertThrowsError(try halfDigestProfile.validate())

        // Omitting both text digest fields explicitly writes 0x0 and "" into ABRuntimeProfile.plist.
        let uuidOnlyProfile = RuntimeOffsetProfile(
            name: "仅 UUID 校验",
            revision: "test-uuid-only",
            version: "2.8.0",
            build: "80",
            unityUUID: "11223344-5566-7788-99aa-bbccddeeff00",
            unityTextSize: nil,
            unityTextSHA256: nil,
            il2cppOffsets: .builtIn2791
        )
        try uuidOnlyProfile.validate()
        let uuidOnlyPlist = try uuidOnlyProfile.encodeToRuntimeProfilePlistData()
        let rawDict = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: uuidOnlyPlist, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(rawDict["unityTextSize"] as? String, "0x0")
        XCTAssertEqual(rawDict["unityTextSHA256"] as? String, "")
        let roundTripped = try RuntimeOffsetProfile.decode(from: uuidOnlyPlist)
        XCTAssertNil(roundTripped.unityTextSize)
        XCTAssertNil(roundTripped.unityTextSHA256)
    }

    func testManualProfileMismatchedTextDigestRejectedBeforeWritingOutput() throws {
        let engine = try IPAPatcherEngine.builtInDefault()
        let kits = try engine.verifyConfiguredKits()
        let manifest = kits[0].manifest

        let futureUUID = "22334455-6677-8899-aabb-ccddeeff0011"
        var cfg = SyntheticIPABuilder.Configuration()
        cfg.version = "2.9.1"
        cfg.build = "101"
        cfg.overrideUnityUUID = futureUUID
        let futureIPA = tempDir.appendingPathComponent("arknights-2.9.1.ipa")
        try SyntheticIPABuilder.createSyntheticIPA(at: futureIPA, manifest: manifest, config: cfg)

        let staleDigestProfile = RuntimeOffsetProfile(
            name: "错误代码段指纹配置",
            revision: "7.5-2.9.1-stale-digest",
            version: "2.9.1",
            build: "101",
            unityUUID: futureUUID,
            unityTextSize: 0x099f_7a28,
            unityTextSHA256: "ef43071f7010d6c429f34bd4b9dd3e347941db43dfd3b47913e146fe98f67443",
            il2cppOffsets: .builtIn2791
        )

        let host = try engine.inspectHost(at: futureIPA)
        let matchResult = try engine.matchCompatibility(
            for: host,
            verifiedKits: kits,
            customProfiles: [staleDigestProfile],
            options: PatchOptions(applyCustomBiliIcons: true, enableAutoAdaptation: false),
            sourceIPAURL: futureIPA
        )
        guard case .matched(let config) = matchResult else {
            return XCTFail("Expected manual profile match by version/build/UUID before Entry 3 digest preflight")
        }

        let outDir = tempDir.appendingPathComponent("must-not-exist", isDirectory: true)
        XCTAssertThrowsError(
            try engine.applyPatch(configuration: config, sourceIPAURL: futureIPA, workingDirectory: outDir)
        ) { err in
            guard case PatchError.incompatibleHost(let report) = err else {
                return XCTFail("Expected incompatibleHost for mismatched __text digest, got \(err)")
            }
            XCTAssertTrue(report.mismatches.contains { $0.kind == .binaryTextDigest })
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outDir.path))
    }

    func testOriginalIconOptionSkipsBiliIconsAndPreservesHostIconKeys() throws {
        let engine = try IPAPatcherEngine.builtInDefault()
        let kits = try engine.verifyConfiguredKits()
        let manifest = kits[0].manifest

        let inputIPA = tempDir.appendingPathComponent("orig-icon-input.ipa")
        try SyntheticIPABuilder.createSyntheticIPA(at: inputIPA, manifest: manifest)

        let session = try engine.openInputSession(at: inputIPA)
        let host = try engine.inspectHost(session: session)
        let matchResult = try engine.matchCompatibility(for: host, verifiedKits: kits, inputSession: session)
        guard case .matched(let config) = matchResult else {
            return XCTFail("Expected match")
        }

        let outDir = tempDir.appendingPathComponent("orig-icon-out", isDirectory: true)
        let options = PatchOptions(applyCustomBiliIcons: false, enableAutoAdaptation: true)
        let result = try engine.applyPatch(
            configuration: config,
            sourceIPAURL: inputIPA,
            workingDirectory: outDir,
            options: options,
            inputSession: session
        )

        XCTAssertFalse(result.appliedCustomBiliIcons)
        XCTAssertTrue(result.suggestedExportFilename.contains("-origicon-"))
        XCTAssertFalse(result.addedEntries.contains { $0.contains("ABAppIcon") })

        // Verify unmodified host binaries were NOT re-deflated (only UnityFramework + Info.plist modified!).
        XCTAssertEqual(result.modifiedEntries.count, 2)

        let outReader = try Zip64Reader(url: result.outputURL)
        XCTAssertFalse(outReader.entryNames.contains { $0.contains("ABAppIcon") })

        let patchedPlistData = try outReader.readData(named: "Payload/Arknights.app/Info.plist")
        let plistObj = try PropertyListSerialization.propertyList(from: patchedPlistData, options: [], format: nil)
        let plist = try XCTUnwrap(plistObj as? [String: Any])
        XCTAssertNil(plist["CFBundleIcons"])
        XCTAssertNil(plist["CFBundleIcons~ipad"])
        let u8 = try XCTUnwrap(plist["U8SDK"] as? [String: Any])
        XCTAssertEqual(u8["Channel"] as? Int, 2)
    }

    func testManualCustomProfileMatchesFutureVersionWithoutUpdatingApp() throws {
        let engine = try IPAPatcherEngine.builtInDefault()
        let kits = try engine.verifyConfiguredKits()
        let manifest = kits[0].manifest

        let futureUUID = "11223344-5566-7788-99aa-bbccddeeff00"
        var cfg = SyntheticIPABuilder.Configuration()
        cfg.version = "2.9.0"
        cfg.build = "99"
        cfg.overrideUnityUUID = futureUUID
        let futureIPA = tempDir.appendingPathComponent("arknights-2.9.0.ipa")
        try SyntheticIPABuilder.createSyntheticIPA(at: futureIPA, manifest: manifest, config: cfg)

        let manualOffsets = IL2CPPOffsetSet(
            sdkInterfaceClassSlot: 0x0c10_0008,
            sdkExternalToolsClassSlot: 0x0c10_0010,
            sdkMetaClassSlot: 0x0c10_0018,
            networkerTypeSlot: 0x0c10_0020,
            networkerExpectedClass: 0x0650_1000,
            gameFlowClassSlot: 0x0c10_0028,
            getNetworkConfigFn: 0x0780_1000,
            overrideNetworkOptionsFn: 0x0780_1200,
            createStringFn: 0x07e0_1000,
            internalSDKMetaFn: 0x06d0_1000,
            sdkMetaCtorFn: 0x06d0_2000,
            clearAuthStatusFn: 0x06d0_3000,
            clearLoginStatusFn: 0x06d0_4000,
            getCurrentSceneFn: 0x0190_1000
        )
        let customProfile = RuntimeOffsetProfile(
            name: "明日方舟 2.9.0 (build 99) 手工适配",
            revision: "7.5-2.9.0-manual-r1",
            version: "2.9.0",
            build: "99",
            unityUUID: futureUUID,
            il2cppOffsets: manualOffsets
        )

        let session = try engine.openInputSession(at: futureIPA)
        let host = try engine.inspectHost(session: session)
        let matchResult = try engine.matchCompatibility(
            for: host,
            verifiedKits: kits,
            customProfiles: [customProfile],
            options: PatchOptions(applyCustomBiliIcons: true, enableAutoAdaptation: false),
            sourceIPAURL: futureIPA,
            inputSession: session
        )

        guard case .matched(let config) = matchResult else {
            return XCTFail("Expected manual custom profile match")
        }
        XCTAssertEqual(config.adaptationMode, .manualCustomProfile)

        let outDir = tempDir.appendingPathComponent("future-manual-out", isDirectory: true)
        let result = try engine.applyPatch(
            configuration: config,
            sourceIPAURL: futureIPA,
            workingDirectory: outDir,
            inputSession: session
        )
        XCTAssertEqual(result.adaptationMode, .manualCustomProfile)
        XCTAssertEqual(result.revision, "7.5-2.9.0-manual-r1")
        XCTAssertEqual(result.suggestedExportFilename, "Arknights-2.9.0-b99-bili-unsigned.ipa")

        // Second run into same outputDir with default `overwriteExistingOutput = false` MUST refuse without deleting first output!
        let firstSHA = try FileHasher.sha256Hex(of: result.outputURL)
        XCTAssertThrowsError(
            try engine.applyPatch(configuration: config, sourceIPAURL: futureIPA, workingDirectory: outDir)
        ) { err in
            guard case PatchError.outputAlreadyExists = err else {
                return XCTFail("Expected outputAlreadyExists, got \(err)")
            }
        }
        XCTAssertEqual(try FileHasher.sha256Hex(of: result.outputURL), firstSHA)

        // Verify injected `ABRuntimeProfile.plist` carries the exact manual offsets.
        let outReader = try Zip64Reader(url: result.outputURL)
        let runtimePlistData = try outReader.readData(named: "Payload/Arknights.app/ABRuntimeProfile.plist")
        let rtProfile = try RuntimeOffsetProfile.decode(from: runtimePlistData)
        XCTAssertEqual(rtProfile.version, "2.9.0")
        XCTAssertEqual(rtProfile.unityUUID, futureUUID)
        XCTAssertEqual(rtProfile.il2cppOffsets, manualOffsets)
    }

    func testSanitizedExportFilenameBlocksPathSeparatorsAndTraversal() {
        let name = PatchApplicator.makeSafeExportFilename(
            version: "../../2.9/evil\\x",
            build: "../99/bad",
            applyCustomBiliIcons: true
        )
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains("\\"))
        XCTAssertFalse(name.contains(".."))
        XCTAssertTrue(name.hasPrefix("Arknights-"))
        XCTAssertTrue(name.hasSuffix("-unsigned.ipa"))
    }

    func testKnownBaseline2791WithWrongUUIDNeverFallsBackToAutoAdaptAndSelfCheckRejectsNonBaseline() throws {
        let engine = try IPAPatcherEngine.builtInDefault()
        let kits = try engine.verifyConfiguredKits()
        let manifest = kits[0].manifest

        // 1. Claims to be 2.7.91 / build 76, but UnityFramework UUID is altered -> must NOT invoke Tier 3 auto-adapt!
        var cfg = SyntheticIPABuilder.Configuration()
        cfg.version = "2.7.91"
        cfg.build = "76"
        cfg.overrideUnityUUID = "99999999-8888-7777-6666-555555555555"
        let tampered2791 = tempDir.appendingPathComponent("tampered-2.7.91.ipa")
        try SyntheticIPABuilder.createSyntheticIPA(at: tampered2791, manifest: manifest, config: cfg)

        let host = try engine.inspectHost(at: tampered2791)
        let matchResult = try engine.matchCompatibility(
            for: host,
            verifiedKits: kits,
            options: PatchOptions(applyCustomBiliIcons: true, enableAutoAdaptation: true),
            sourceIPAURL: tampered2791
        )
        guard case .incompatible(let report) = matchResult else {
            return XCTFail("Known baseline version with mismatched UUID must be rejected as incompatible")
        }
        XCTAssertFalse(report.autoAdaptationAttempted)

        // 2. selfCheckAutoResolver on non-baseline IPA must fail cleanly before comparing against 2.7.91 offsets.
        XCTAssertThrowsError(try engine.selfCheckAutoResolver(ipaURL: tampered2791)) { err in
            guard case PatchError.autoResolutionFailed(let msg) = err else {
                return XCTFail("Expected autoResolutionFailed, got \(err)")
            }
            XCTAssertTrue(msg.contains("原版基准包"))
        }
    }

    func testIL2CPPAutoResolverWithChainedFixupsByteLevelABIAndAmbiguityGating() throws {
        let host = HostIPAProfile(
            sourceFileName: "Arknights-2.8.0.ipa",
            sourceFileSize: 100_000,
            appRoot: "Payload/Arknights.app/",
            displayName: "明日方舟",
            bundleID: "com.hypergryph.arknights",
            version: "2.8.0",
            build: "80",
            executableName: "Arknights",
            minimumOSVersion: "13.0",
            entryCount: 10,
            binaries: []
        )

        // 1. Valid fixture with Chained Fixups, high-bit UInt64 garbage in __DATA, compiled fieldOffsets & instance sizes.
        let validFixture = try SyntheticIL2CPPFixture.build(
            useChainedFixups: true,
            networkConfigStringFields: 12,
            networkConfigDevOffsetOverride: nil,
            networkConfigSizeOverride: nil,
            emitAmbiguousDoubleIntersect: false,
            emitDuplicateNetworkerSlotInDataConst: false
        )

        let resolver = IL2CPPAutoResolver()
        let report = try resolver.resolve(
            globalMetadataData: validFixture.globalMetadata,
            unityFrameworkData: validFixture.unityFramework,
            hostProfile: host
        )

        XCTAssertTrue(report.isConfirmedCompatible)
        let profile = try XCTUnwrap(report.profile)
        XCTAssertEqual(report.metadataVersion, 29)
        XCTAssertEqual(profile.unityUUID, validFixture.unityUUID)
        XCTAssertEqual(profile.il2cppOffsets, validFixture.expectedOffsets)
        XCTAssertEqual(report.sdkMetaFieldsVerified.count, 6)
        XCTAssertEqual(report.networkConfigStringFieldCount, 12)
        XCTAssertNotNil(profile.unityTextSHA256)

        let comparisons = IL2CPPAutoResolver.compare(resolved: profile.il2cppOffsets, against: validFixture.expectedOffsets)
        XCTAssertEqual(comparisons.count, 14)
        XCTAssertTrue(comparisons.allSatisfy(\.isMatch))

        let sdkInterfaceItem = try XCTUnwrap(report.items.first { $0.key == "sdkInterfaceClassSlot" })
        XCTAssertTrue(sdkInterfaceItem.strategy.contains("ARM64"))
        XCTAssertEqual(sdkInterfaceItem.candidateCount, 1)

        // 2. Same field types & order, but compiled `NetworkConfig` byte size changed from 104 -> 112 -> MUST REJECT!
        let shiftedSizeFixture = try SyntheticIL2CPPFixture.build(
            useChainedFixups: true,
            networkConfigStringFields: 12,
            networkConfigDevOffsetOverride: nil,
            networkConfigSizeOverride: 128, // 128 - 16 = 112 != 104
            emitAmbiguousDoubleIntersect: false,
            emitDuplicateNetworkerSlotInDataConst: false
        )
        XCTAssertThrowsError(
            try resolver.resolve(
                globalMetadataData: shiftedSizeFixture.globalMetadata,
                unityFrameworkData: shiftedSizeFixture.unityFramework,
                hostProfile: host
            )
        ) { err in
            guard case PatchError.autoResolutionFailed(let msg) = err else {
                return XCTFail("Expected autoResolutionFailed, got \(err)")
            }
            XCTAssertTrue(msg.contains("104"))
        }

        // 3. Two slots both intersected by helper ARM64 ADRP+LDR -> MUST return `.candidatesUnverified` (never silently pick first!).
        let ambiguousFixture = try SyntheticIL2CPPFixture.build(
            useChainedFixups: true,
            networkConfigStringFields: 12,
            networkConfigDevOffsetOverride: nil,
            networkConfigSizeOverride: nil,
            emitAmbiguousDoubleIntersect: true,
            emitDuplicateNetworkerSlotInDataConst: false
        )
        let ambigReport = try resolver.resolve(
            globalMetadataData: ambiguousFixture.globalMetadata,
            unityFrameworkData: ambiguousFixture.unityFramework,
            hostProfile: host
        )
        XCTAssertFalse(ambigReport.isConfirmedCompatible)
        XCTAssertNil(ambigReport.profile)
        XCTAssertFalse(ambigReport.unverifiedReasons.isEmpty)

        // 4. Multiple candidates where ONLY ONE sits in primary `__DATA.__data` (and another in `__DATA_CONST.__const`),
        // without cross-check disambiguation -> MUST return `.candidatesUnverified` (never auto-approve by section alone!).
        let sectionHintOnlyFixture = try SyntheticIL2CPPFixture.build(
            useChainedFixups: true,
            networkConfigStringFields: 12,
            networkConfigDevOffsetOverride: nil,
            networkConfigSizeOverride: nil,
            emitAmbiguousDoubleIntersect: false,
            emitDuplicateNetworkerSlotInDataConst: true
        )
        let sectionHintReport = try resolver.resolve(
            globalMetadataData: sectionHintOnlyFixture.globalMetadata,
            unityFrameworkData: sectionHintOnlyFixture.unityFramework,
            hostProfile: host
        )
        XCTAssertFalse(sectionHintReport.isConfirmedCompatible)
        XCTAssertNil(sectionHintReport.profile)
        XCTAssertTrue(
            sectionHintReport.unverifiedReasons.contains { $0.contains("networkerTypeSlot") && $0.contains("__DATA.__data") },
            "Expected unverified reason noting __DATA.__data hint for networkerTypeSlot, got: \(sectionHintReport.unverifiedReasons)"
        )
        let networkerItem = try XCTUnwrap(sectionHintReport.items.first { $0.key == "networkerTypeSlot" })
        XCTAssertEqual(networkerItem.candidateCount, 2)
    }

    func testCancellationPropagatesUnwrappedFromAutoResolver() async throws {
        let engine = try IPAPatcherEngine.builtInDefault()
        let kits = try engine.verifyConfiguredKits()
        let ipaURL = tempDir.appendingPathComponent("cancel-auto.ipa")
        try SyntheticIPABuilder.createSyntheticIPA(at: ipaURL, manifest: kits[0].manifest)
        let host = try engine.inspectHost(at: ipaURL)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try IL2CPPAutoResolver().resolve(sourceIPAURL: ipaURL, hostProfile: host)
        }
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected unwrapped CancellationError!
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }
}

// MARK: - Synthetic IL2CPP v29 + ARM64 Mach-O Fixture Builder (with Parameters, FieldOffsets & TypeDefinitionSizes)

private struct SyntheticIL2CPPFixture {
    let unityUUID: String
    let globalMetadata: Data
    let unityFramework: Data
    let expectedOffsets: IL2CPPOffsetSet

    static func build(
        useChainedFixups: Bool,
        networkConfigStringFields: Int,
        networkConfigDevOffsetOverride: Int32?,
        networkConfigSizeOverride: UInt32?,
        emitAmbiguousDoubleIntersect: Bool,
        emitDuplicateNetworkerSlotInDataConst: Bool
    ) throws -> SyntheticIL2CPPFixture {
        var strBytes = Data([0])
        var strMap: [String: UInt32] = ["": 0]
        func addStr(_ s: String) -> UInt32 {
            if let existing = strMap[s] { return existing }
            let idx = UInt32(strBytes.count)
            strBytes.append(contentsOf: s.utf8)
            strBytes.append(0)
            strMap[s] = idx
            return idx
        }

        // Types:
        // 0: System.String (mscorlib.dll)
        // 1: Torappu.Singleton`1 (Assembly-CSharp.dll)
        // 2: Torappu.Network.NetworkConfig (Assembly-CSharp.dll) -> ValueType (104B)
        // 3: Torappu.Network.Networker (Assembly-CSharp.dll) -> parentIndex = 9 (GENERICINST Singleton<Networker>)
        // 4: U8.SDK.U8SDKInterface (Assembly-CSharp.dll)
        // 5: U8.SDK.SDKExternalTools (Assembly-CSharp.dll)
        // 6: U8.SDK.SDKMeta (Assembly-CSharp.dll)
        // 7: Torappu.GameFlowController (Assembly-CSharp.dll)
        // 8: Torappu.Network.NetworkOverride (Assembly-CSharp.dll) -> ValueType (112B: bool @ 0, NetworkConfig @ 8)
        //
        // Il2CppType table indices (types[]):
        // 0: STRING (0x0e)
        // 1: CLASS Singleton`1
        // 2: VALUETYPE NetworkConfig
        // 3: CLASS Networker
        // 4: CLASS U8SDKInterface
        // 5: CLASS SDKExternalTools
        // 6: CLASS SDKMeta
        // 7: CLASS GameFlowController
        // 8: VALUETYPE NetworkOverride
        // 9: GENERICINST Singleton<Networker>
        // 10: BOOLEAN (0x02)
        // 11: VOID (0x01)
        // 12: PTR (0x0f) (sbyte*)
        // 13: I4 (0x08) (int32)

        var fields: [(nameIdx: UInt32, typeIdx: Int32, token: UInt32)] = []
        let netCfgFieldStart = Int32(fields.count)
        for i in 0..<networkConfigStringFields {
            fields.append((addStr("url\(i)"), 0, UInt32(0x0400_0001 + i)))
        }
        fields.append((addStr("dev"), 10, UInt32(0x0400_0099)))
        let netCfgFieldCount = UInt16(fields.count) - UInt16(netCfgFieldStart)

        let sdkMetaFieldStart = Int32(fields.count)
        let metaNames = ["appID", "appKey", "channel", "worldId", "extension", "appCode"]
        for (i, n) in metaNames.enumerated() {
            fields.append((addStr(n), 0, UInt32(0x0400_0101 + i)))
        }
        let sdkMetaFieldCount = UInt16(metaNames.count)

        let netOverrideFieldStart = Int32(fields.count)
        fields.append((addStr("enabled"), 10, 0x0400_0201)) // BOOLEAN
        fields.append((addStr("config"), 2, 0x0400_0202))   // VALUETYPE NetworkConfig
        let netOverrideFieldCount: UInt16 = 2

        // Parameter definitions table
        var params: [(nameIdx: UInt32, token: UInt32, typeIdx: Int32)] = []
        func addParams(_ typeIndices: [Int32]) -> Int32 {
            let start = Int32(params.count)
            for (i, ti) in typeIndices.enumerated() {
                params.append((addStr("p\(i)"), UInt32(0x0800_0001 + params.count), ti))
            }
            return start
        }

        let pCreateString = addParams([12, 13])       // (sbyte*, int32)
        let pOverrideNet = addParams([8, 13])         // (NetworkOverride, int32)
        let pSDKMetaCtorStr = addParams([0])          // (string)
        let pSDKMetaCtorInt = addParams([13])         // decoy 1-param overload (int32) to prove typed signature match!

        struct MethodSpecIn {
            let name: String
            let declaringType: Int32
            let returnType: Int32
            let paramStart: Int32
            let token: UInt32
            let paramCount: UInt16
        }
        let methodsIn: [MethodSpecIn] = [
            // mscorlib.dll
            .init(name: "CreateStringForSByteConstructor", declaringType: 0, returnType: 0, paramStart: pCreateString, token: 0x0600_0001, paramCount: 2),
            // Assembly-CSharp.dll
            .init(name: "get_instance", declaringType: 1, returnType: 11, paramStart: 0, token: 0x0600_0001, paramCount: 0),
            .init(name: "get_networkConfig", declaringType: 3, returnType: 2, paramStart: 0, token: 0x0600_0002, paramCount: 0),
            .init(name: "OverrideNetworkOptions", declaringType: 3, returnType: 11, paramStart: pOverrideNet, token: 0x0600_0003, paramCount: 2),
            .init(name: "get_Instance", declaringType: 4, returnType: 4, paramStart: 0, token: 0x0600_0004, paramCount: 0),
            .init(name: "_InternalSDKMeta", declaringType: 4, returnType: 6, paramStart: 0, token: 0x0600_0005, paramCount: 0),
            .init(name: "ClearAuthStatus", declaringType: 4, returnType: 11, paramStart: 0, token: 0x0600_0006, paramCount: 0),
            .init(name: "ClearLoginStatus", declaringType: 4, returnType: 11, paramStart: 0, token: 0x0600_0007, paramCount: 0),
            .init(name: "GetInstance", declaringType: 5, returnType: 5, paramStart: 0, token: 0x0600_0008, paramCount: 0),
            .init(name: ".ctor", declaringType: 6, returnType: 11, paramStart: pSDKMetaCtorInt, token: 0x0600_0009, paramCount: 1), // decoy int overload!
            .init(name: ".ctor", declaringType: 6, returnType: 11, paramStart: pSDKMetaCtorStr, token: 0x0600_000A, paramCount: 1), // real string overload!
            .init(name: "get_currentScene", declaringType: 7, returnType: 0, paramStart: 0, token: 0x0600_000B, paramCount: 0),
        ]

        struct TypeDefIn {
            let ns: String
            let name: String
            let byvalTypeIdx: Int32
            let parentIdx: Int32
            let fieldStart: Int32
            let fieldCount: UInt16
            let methodStart: Int32
            let methodCount: UInt16
        }
        let typeDefsIn: [TypeDefIn] = [
            .init(ns: "System", name: "String", byvalTypeIdx: 0, parentIdx: -1, fieldStart: 0, fieldCount: 0, methodStart: 0, methodCount: 1),
            .init(ns: "Torappu", name: "Singleton`1", byvalTypeIdx: 1, parentIdx: -1, fieldStart: 0, fieldCount: 0, methodStart: 1, methodCount: 1),
            .init(ns: "Torappu.Network", name: "NetworkConfig", byvalTypeIdx: 2, parentIdx: -1, fieldStart: netCfgFieldStart, fieldCount: netCfgFieldCount, methodStart: 0, methodCount: 0),
            .init(ns: "Torappu.Network", name: "Networker", byvalTypeIdx: 3, parentIdx: 9, fieldStart: 0, fieldCount: 0, methodStart: 2, methodCount: 2),
            .init(ns: "U8.SDK", name: "U8SDKInterface", byvalTypeIdx: 4, parentIdx: -1, fieldStart: 0, fieldCount: 0, methodStart: 4, methodCount: 4),
            .init(ns: "U8.SDK", name: "SDKExternalTools", byvalTypeIdx: 5, parentIdx: -1, fieldStart: 0, fieldCount: 0, methodStart: 8, methodCount: 1),
            .init(ns: "U8.SDK", name: "SDKMeta", byvalTypeIdx: 6, parentIdx: -1, fieldStart: sdkMetaFieldStart, fieldCount: sdkMetaFieldCount, methodStart: 9, methodCount: 2),
            .init(ns: "Torappu", name: "GameFlowController", byvalTypeIdx: 7, parentIdx: -1, fieldStart: 0, fieldCount: 0, methodStart: 11, methodCount: 1),
            .init(ns: "Torappu.Network", name: "NetworkOverride", byvalTypeIdx: 8, parentIdx: -1, fieldStart: netOverrideFieldStart, fieldCount: netOverrideFieldCount, methodStart: 0, methodCount: 0),
        ]

        let imgMscorlibNameIdx = addStr("mscorlib.dll")
        let imgCSharpNameIdx = addStr("Assembly-CSharp.dll")
        let methodNameIndices = methodsIn.map { addStr($0.name) }
        let typeNameIndices = typeDefsIn.map { (addStr($0.name), addStr($0.ns)) }

        var meta = Data(count: 0x100)
        func putU32(_ buf: inout Data, at off: Int, _ val: UInt32) {
            var le = val.littleEndian
            withUnsafeBytes(of: &le) { buf.replaceSubrange(off..<(off + 4), with: $0) }
        }
        func putI32(_ buf: inout Data, at off: Int, _ val: Int32) {
            putU32(&buf, at: off, UInt32(bitPattern: val))
        }
        func putU16(_ buf: inout Data, at off: Int, _ val: UInt16) {
            var le = val.littleEndian
            withUnsafeBytes(of: &le) { buf.replaceSubrange(off..<(off + 2), with: $0) }
        }
        func putU64(_ buf: inout Data, at off: Int, _ val: UInt64) {
            var le = val.littleEndian
            withUnsafeBytes(of: &le) { buf.replaceSubrange(off..<(off + 8), with: $0) }
        }

        putU32(&meta, at: 0x00, 0xFAB1_1BAF)
        putI32(&meta, at: 0x04, 29)

        let finalStrOff = UInt32(meta.count)
        meta.append(strBytes)
        putU32(&meta, at: 0x18, finalStrOff)
        putI32(&meta, at: 0x1C, Int32(strBytes.count))

        let finalMethodsOff = UInt32(meta.count)
        for (i, m) in methodsIn.enumerated() {
            var rec = Data(count: 32)
            putU32(&rec, at: 0x00, methodNameIndices[i])
            putI32(&rec, at: 0x04, m.declaringType)
            putI32(&rec, at: 0x08, m.returnType)
            putI32(&rec, at: 0x0C, m.paramStart)
            putU32(&rec, at: 0x14, m.token)
            putU16(&rec, at: 0x1E, m.paramCount)
            meta.append(rec)
        }
        putU32(&meta, at: 0x30, finalMethodsOff)
        putI32(&meta, at: 0x34, Int32(methodsIn.count * 32))

        let finalParamsOff = UInt32(meta.count)
        for p in params {
            var rec = Data(count: 12)
            putU32(&rec, at: 0x00, p.nameIdx)
            putU32(&rec, at: 0x04, p.token)
            putI32(&rec, at: 0x08, p.typeIdx)
            meta.append(rec)
        }
        putU32(&meta, at: 0x58, finalParamsOff)
        putI32(&meta, at: 0x5C, Int32(params.count * 12))

        let finalFieldsOff = UInt32(meta.count)
        for f in fields {
            var rec = Data(count: 12)
            putU32(&rec, at: 0x00, f.nameIdx)
            putI32(&rec, at: 0x04, f.typeIdx)
            putU32(&rec, at: 0x08, f.token)
            meta.append(rec)
        }
        putU32(&meta, at: 0x60, finalFieldsOff)
        putI32(&meta, at: 0x64, Int32(fields.count * 12))

        let finalTypesOff = UInt32(meta.count)
        for (i, td) in typeDefsIn.enumerated() {
            var rec = Data(count: 88)
            putU32(&rec, at: 0x00, typeNameIndices[i].0)
            putU32(&rec, at: 0x04, typeNameIndices[i].1)
            putI32(&rec, at: 0x08, td.byvalTypeIdx)
            putI32(&rec, at: 0x0C, -1)
            putI32(&rec, at: 0x10, td.parentIdx)
            putI32(&rec, at: 0x20, td.fieldStart)
            putI32(&rec, at: 0x24, td.methodStart)
            putU16(&rec, at: 0x40, td.methodCount)
            putU16(&rec, at: 0x44, td.fieldCount)
            meta.append(rec)
        }
        putU32(&meta, at: 0xA0, finalTypesOff)
        putI32(&meta, at: 0xA4, Int32(typeDefsIn.count * 88))

        let finalImagesOff = UInt32(meta.count)
        var img0 = Data(count: 40)
        putU32(&img0, at: 0x00, imgMscorlibNameIdx)
        putI32(&img0, at: 0x08, 0)
        putU32(&img0, at: 0x0C, 1)
        var img1 = Data(count: 40)
        putU32(&img1, at: 0x00, imgCSharpNameIdx)
        putI32(&img1, at: 0x08, 1)
        putU32(&img1, at: 0x0C, 8)
        meta.append(img0)
        meta.append(img1)
        putU32(&meta, at: 0xA8, finalImagesOff)
        putI32(&meta, at: 0xAC, 80)

        // Build 64-bit arm64 Mach-O `UnityFramework` (0x0000 ..< 0xE000):
        //   0x0000 ..< 0x8000 : __TEXT (__text + __cstring)
        //   0x8000 ..< 0xC000 : __DATA (__data)
        //   0xC000 ..< 0xD000 : __DATA_CONST (__const)
        //   0xD000 ..< 0xE000 : __LINKEDIT (LC_DYLD_CHAINED_FIXUPS)
        var macho = Data(count: 0xE000)
        let uuidStr = "aabbccdd-1122-3344-5566-77889900aabb"
        let u = UUID(uuidString: uuidStr)!.uuid
        let uuidBytes: [UInt8] = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]

        func encodePtr(_ rva: UInt64) -> UInt64 {
            useChainedFixups ? ((rva & 0x0000_000F_FFFF_FFFF) | (UInt64(2) << 51)) : rva
        }

        // Plant high-bit UInt64 garbage + false typeDefCount pair in __DATA to prove safe UInt64 -> Int conversion never crashes!
        putU64(&macho, at: 0x8080, UInt64.max)
        putU64(&macho, at: 0x8088, 0x8000_0000_0000_1234)
        putU64(&macho, at: 0x80C0, UInt64(typeDefsIn.count))
        putU64(&macho, at: 0x80D0, UInt64(typeDefsIn.count))

        let rvaCreateString: UInt64 = 0x4100
        let rvaSingletonGetInst: UInt64 = 0x4180
        let rvaGetNetConfig: UInt64 = 0x4200
        let rvaOverrideNet: UInt64 = 0x4280
        let rvaSDKInterfaceGetInst: UInt64 = 0x4300
        let rvaInternalSDKMeta: UInt64 = 0x4380
        let rvaClearAuth: UInt64 = 0x4400
        let rvaClearLogin: UInt64 = 0x4480
        let rvaSDKExternalGetInst: UInt64 = 0x4500
        let rvaSDKMetaCtorDecoy: UInt64 = 0x4580
        let rvaSDKMetaCtorReal: UInt64 = 0x4600
        let rvaGetCurrentScene: UInt64 = 0x4680
        let rvaGenericSingletonGetInst: UInt64 = 0x4700

        let slotSDKInterface: UInt64 = 0x8010
        let slotSDKExternal: UInt64 = 0x8020
        let slotSDKMeta: UInt64 = 0x8030
        let slotGameFlow: UInt64 = 0x8040
        let slotNetworkerRef: UInt64 = 0x8050
        let slotSDKInterfaceDup: UInt64 = 0x8060

        func emitADRPAndLDR(at methodRVA: UInt64, targetSlotRVAs: [UInt64]) {
            var pc = methodRVA
            for targetSlotRVA in targetSlotRVAs {
                let deltaPages = Int64((targetSlotRVA & ~0xFFF) - (pc & ~0xFFF)) >> 12
                let imm21 = UInt32(bitPattern: Int32(deltaPages)) & 0x1F_FFFF
                let immlo = imm21 & 0x3
                let immhi = (imm21 >> 2) & 0x7_FFFF
                let adrp: UInt32 = 0x9000_0000 | (immlo << 29) | (immhi << 5) | 8
                let imm12 = UInt32((targetSlotRVA & 0xFFF) / 8)
                let ldr: UInt32 = 0xF940_0000 | (imm12 << 10) | (8 << 5) | 0
                putU32(&macho, at: Int(pc), adrp)
                putU32(&macho, at: Int(pc) + 4, ldr)
                pc += 8
            }
            putU32(&macho, at: Int(pc), 0xD65F_03C0) // RET
        }
        emitADRPAndLDR(
            at: rvaSDKInterfaceGetInst,
            targetSlotRVAs: emitAmbiguousDoubleIntersect ? [slotSDKInterface, slotSDKInterfaceDup] : [slotSDKInterface]
        )
        emitADRPAndLDR(at: rvaSDKExternalGetInst, targetSlotRVAs: [slotSDKExternal])
        emitADRPAndLDR(at: rvaInternalSDKMeta, targetSlotRVAs: [slotSDKMeta])
        emitADRPAndLDR(at: rvaGetCurrentScene, targetSlotRVAs: [slotGameFlow])

        let strMscorlibRVA: UInt64 = 0x7000
        let strCSharpRVA: UInt64 = 0x7020
        macho.replaceSubrange(Int(strMscorlibRVA)..<(Int(strMscorlibRVA) + 13), with: Data("mscorlib.dll\0".utf8))
        macho.replaceSubrange(Int(strCSharpRVA)..<(Int(strCSharpRVA) + 20), with: Data("Assembly-CSharp.dll\0".utf8))

        putU64(&macho, at: Int(slotSDKInterface), IL2CPPAutoResolver.encodeMetadataUsage(usage: 1, index: 4))
        putU64(&macho, at: Int(slotSDKExternal), IL2CPPAutoResolver.encodeMetadataUsage(usage: 1, index: 5))
        putU64(&macho, at: Int(slotSDKMeta), IL2CPPAutoResolver.encodeMetadataUsage(usage: 1, index: 6))
        putU64(&macho, at: Int(slotGameFlow), IL2CPPAutoResolver.encodeMetadataUsage(usage: 1, index: 7))
        putU64(&macho, at: Int(slotNetworkerRef), IL2CPPAutoResolver.encodeMetadataUsage(usage: 6, index: 0))
        if emitDuplicateNetworkerSlotInDataConst {
            // Second hit sits in `__DATA_CONST.__const` (0xC010), while `slotNetworkerRef` is the only hit in `__DATA.__data`.
            putU64(&macho, at: 0xC010, IL2CPPAutoResolver.encodeMetadataUsage(usage: 6, index: 0))
        }
        putU64(&macho, at: Int(slotSDKInterfaceDup), IL2CPPAutoResolver.encodeMetadataUsage(usage: 1, index: 4))

        let mscorlibPtrsRVA: UInt64 = 0x8100
        putU64(&macho, at: Int(mscorlibPtrsRVA), encodePtr(rvaCreateString))

        let csharpPtrsRVA: UInt64 = 0x8120
        let csharpRVAs: [UInt64] = [
            rvaSingletonGetInst, rvaGetNetConfig, rvaOverrideNet,
            rvaSDKInterfaceGetInst, rvaInternalSDKMeta, rvaClearAuth, rvaClearLogin,
            rvaSDKExternalGetInst, rvaSDKMetaCtorDecoy, rvaSDKMetaCtorReal, rvaGetCurrentScene,
        ]
        for (i, fn) in csharpRVAs.enumerated() {
            putU64(&macho, at: Int(csharpPtrsRVA) + i * 8, encodePtr(fn))
        }

        let modMscorlibRVA: UInt64 = 0x8200
        putU64(&macho, at: Int(modMscorlibRVA) + 0, encodePtr(strMscorlibRVA))
        putU64(&macho, at: Int(modMscorlibRVA) + 8, 1)
        putU64(&macho, at: Int(modMscorlibRVA) + 16, encodePtr(mscorlibPtrsRVA))

        let modCSharpRVA: UInt64 = 0x8240
        putU64(&macho, at: Int(modCSharpRVA) + 0, encodePtr(strCSharpRVA))
        putU64(&macho, at: Int(modCSharpRVA) + 8, UInt64(csharpRVAs.count))
        putU64(&macho, at: Int(modCSharpRVA) + 16, encodePtr(csharpPtrsRVA))

        let codeGenArrayRVA: UInt64 = 0x8280
        putU64(&macho, at: Int(codeGenArrayRVA) + 0, encodePtr(modMscorlibRVA))
        putU64(&macho, at: Int(codeGenArrayRVA) + 8, encodePtr(modCSharpRVA))

        let genMethodPtrsRVA: UInt64 = 0x82A0
        putU64(&macho, at: Int(genMethodPtrsRVA), encodePtr(rvaGenericSingletonGetInst))

        let codeRegRVA: UInt64 = 0x8300
        putU64(&macho, at: Int(codeRegRVA) + 2 * 8, 1)
        putU64(&macho, at: Int(codeRegRVA) + 3 * 8, encodePtr(genMethodPtrsRVA))
        putU64(&macho, at: Int(codeRegRVA) + 13 * 8, 2)
        putU64(&macho, at: Int(codeRegRVA) + 14 * 8, encodePtr(codeGenArrayRVA))

        let typesStructBase: UInt64 = 0x8400
        let genericClassRVA: UInt64 = 0x8600
        let typeConfigs: [(data: UInt64, typeEnum: UInt8, isPtr: Bool)] = [
            (0, 0x0e, false),              // 0: STRING
            (1, 0x12, false),              // 1: CLASS Singleton`1
            (2, 0x11, false),              // 2: VALUETYPE NetworkConfig
            (3, 0x12, false),              // 3: CLASS Networker
            (4, 0x12, false),              // 4: CLASS U8SDKInterface
            (5, 0x12, false),              // 5: CLASS SDKExternalTools
            (6, 0x12, false),              // 6: CLASS SDKMeta
            (7, 0x12, false),              // 7: CLASS GameFlowController
            (8, 0x11, false),              // 8: VALUETYPE NetworkOverride
            (genericClassRVA, 0x15, true), // 9: GENERICINST Singleton<Networker>
            (0, 0x02, false),              // 10: BOOLEAN
            (0, 0x01, false),              // 11: VOID
            (0, 0x0f, false),              // 12: PTR
            (0, 0x08, false),              // 13: I4
        ]
        let typesPtrArrayRVA: UInt64 = 0x8500
        for (i, tc) in typeConfigs.enumerated() {
            let tRVA = typesStructBase + UInt64(i * 16)
            putU64(&macho, at: Int(tRVA), tc.isPtr ? encodePtr(tc.data) : tc.data)
            putU32(&macho, at: Int(tRVA) + 8, UInt32(tc.typeEnum) << 16)
            putU64(&macho, at: Int(typesPtrArrayRVA) + i * 8, encodePtr(tRVA))
        }

        putU64(&macho, at: Int(genericClassRVA), encodePtr(typesStructBase + 1 * 16))

        let argvRVA: UInt64 = 0x8640
        putU64(&macho, at: Int(argvRVA), encodePtr(typesStructBase + 3 * 16))
        let genInst0RVA: UInt64 = 0x8660
        putU64(&macho, at: Int(genInst0RVA) + 0, 1)
        putU64(&macho, at: Int(genInst0RVA) + 8, encodePtr(argvRVA))
        let genInstsPtrArrayRVA: UInt64 = 0x8680
        putU64(&macho, at: Int(genInstsPtrArrayRVA), encodePtr(genInst0RVA))

        let methodSpecsRVA: UInt64 = 0x86A0
        putI32(&macho, at: Int(methodSpecsRVA) + 0, 1)
        putI32(&macho, at: Int(methodSpecsRVA) + 4, 0)
        putI32(&macho, at: Int(methodSpecsRVA) + 8, -1)

        let genMethodTableRVA: UInt64 = 0x86C0
        putI32(&macho, at: Int(genMethodTableRVA) + 0, 0)
        putI32(&macho, at: Int(genMethodTableRVA) + 4, 0)
        putI32(&macho, at: Int(genMethodTableRVA) + 8, 0)
        putI32(&macho, at: Int(genMethodTableRVA) + 12, -1)

        // Compiled `fieldOffsets` per TypeDef (0x8900 ptr array -> 0x8A00.. offset arrays).
        let fieldOffsetsPtrArrayRVA: UInt64 = 0x8900
        let netCfgOffsetsRVA: UInt64 = 0x8A00
        for i in 0..<networkConfigStringFields {
            putI32(&macho, at: Int(netCfgOffsetsRVA) + i * 4, Int32(16 + i * 8)) // ValueType includes 16B header
        }
        putI32(&macho, at: Int(netCfgOffsetsRVA) + networkConfigStringFields * 4, networkConfigDevOffsetOverride ?? Int32(16 + 96))

        let sdkMetaOffsetsRVA: UInt64 = 0x8A80
        for i in 0..<6 {
            putI32(&macho, at: Int(sdkMetaOffsetsRVA) + i * 4, Int32(0x10 + i * 8))
        }

        let netOverrideOffsetsRVA: UInt64 = 0x8AC0
        putI32(&macho, at: Int(netOverrideOffsetsRVA) + 0, Int32(16 + 0)) // enabled @ 0
        putI32(&macho, at: Int(netOverrideOffsetsRVA) + 4, Int32(16 + 8)) // config @ 8

        putU64(&macho, at: Int(fieldOffsetsPtrArrayRVA) + 2 * 8, encodePtr(netCfgOffsetsRVA))
        putU64(&macho, at: Int(fieldOffsetsPtrArrayRVA) + 6 * 8, encodePtr(sdkMetaOffsetsRVA))
        putU64(&macho, at: Int(fieldOffsetsPtrArrayRVA) + 8 * 8, encodePtr(netOverrideOffsetsRVA))

        // Compiled `typeDefinitionsSizes` per TypeDef (0x8B00 ptr array -> 0x8C00.. Il2CppTypeDefinitionSizes[16B]).
        let typeSizesPtrArrayRVA: UInt64 = 0x8B00
        let netCfgSizeStructRVA: UInt64 = 0x8C00
        putU32(&macho, at: Int(netCfgSizeStructRVA), networkConfigSizeOverride ?? UInt32(16 + 104))
        let netOverrideSizeStructRVA: UInt64 = 0x8C20
        putU32(&macho, at: Int(netOverrideSizeStructRVA), UInt32(16 + 112))
        let sdkMetaSizeStructRVA: UInt64 = 0x8C40
        putU32(&macho, at: Int(sdkMetaSizeStructRVA), UInt32(0x10 + 48))

        putU64(&macho, at: Int(typeSizesPtrArrayRVA) + 2 * 8, encodePtr(netCfgSizeStructRVA))
        putU64(&macho, at: Int(typeSizesPtrArrayRVA) + 6 * 8, encodePtr(sdkMetaSizeStructRVA))
        putU64(&macho, at: Int(typeSizesPtrArrayRVA) + 8 * 8, encodePtr(netOverrideSizeStructRVA))

        // Il2CppMetadataRegistration at 0x8800
        let metaRegRVA: UInt64 = 0x8800
        putU64(&macho, at: Int(metaRegRVA) + 2 * 8, 1)
        putU64(&macho, at: Int(metaRegRVA) + 3 * 8, encodePtr(genInstsPtrArrayRVA))
        putU64(&macho, at: Int(metaRegRVA) + 4 * 8, 1)
        putU64(&macho, at: Int(metaRegRVA) + 5 * 8, encodePtr(genMethodTableRVA))
        putU64(&macho, at: Int(metaRegRVA) + 6 * 8, UInt64(typeConfigs.count))
        putU64(&macho, at: Int(metaRegRVA) + 7 * 8, encodePtr(typesPtrArrayRVA))
        putU64(&macho, at: Int(metaRegRVA) + 8 * 8, 1)
        putU64(&macho, at: Int(metaRegRVA) + 9 * 8, encodePtr(methodSpecsRVA))
        putU64(&macho, at: Int(metaRegRVA) + 10 * 8, UInt64(typeDefsIn.count))
        putU64(&macho, at: Int(metaRegRVA) + 11 * 8, encodePtr(fieldOffsetsPtrArrayRVA))
        putU64(&macho, at: Int(metaRegRVA) + 12 * 8, UInt64(typeDefsIn.count))
        putU64(&macho, at: Int(metaRegRVA) + 13 * 8, encodePtr(typeSizesPtrArrayRVA))

        func makeSegment(name: String, vmAddr: UInt64, vmSize: UInt64, fileOff: UInt64, fileSize: UInt64, sections: [(String, String, UInt64, UInt64, UInt32, UInt32)]) -> Data {
            let cmdSize = 72 + sections.count * 80
            var seg = Data(count: cmdSize)
            putU32(&seg, at: 0, 0x19)
            putU32(&seg, at: 4, UInt32(cmdSize))
            seg.replaceSubrange(8..<(8 + name.utf8.count), with: Data(name.utf8))
            putU64(&seg, at: 24, vmAddr)
            putU64(&seg, at: 32, vmSize)
            putU64(&seg, at: 40, fileOff)
            putU64(&seg, at: 48, fileSize)
            putU32(&seg, at: 64, UInt32(sections.count))
            for (i, s) in sections.enumerated() {
                let b = 72 + i * 80
                seg.replaceSubrange(b..<(b + s.0.utf8.count), with: Data(s.0.utf8))
                seg.replaceSubrange((b + 16)..<(b + 16 + s.1.utf8.count), with: Data(s.1.utf8))
                putU64(&seg, at: b + 32, s.2)
                putU64(&seg, at: b + 40, s.3)
                putU32(&seg, at: b + 48, s.4)
                putU32(&seg, at: b + 64, s.5)
            }
            return seg
        }

        let segText = makeSegment(
            name: "__TEXT", vmAddr: 0x0, vmSize: 0x8000, fileOff: 0x0, fileSize: 0x8000,
            sections: [
                ("__text", "__TEXT", 0x4000, 0x3000, 0x4000, 0x8000_0400),
                ("__cstring", "__TEXT", 0x7000, 0x1000, 0x7000, 0x0000_0002),
            ]
        )
        let segData = makeSegment(
            name: "__DATA", vmAddr: 0x8000, vmSize: 0x4000, fileOff: 0x8000, fileSize: 0x4000,
            sections: [
                ("__data", "__DATA", 0x8000, 0x4000, 0x8000, 0x0),
            ]
        )
        let segDataConst = makeSegment(
            name: "__DATA_CONST", vmAddr: 0xC000, vmSize: 0x1000, fileOff: 0xC000, fileSize: 0x1000,
            sections: [
                ("__const", "__DATA_CONST", 0xC000, 0x1000, 0xC000, 0x0),
            ]
        )
        var lcUUID = Data(count: 24)
        putU32(&lcUUID, at: 0, 0x1b)
        putU32(&lcUUID, at: 4, 24)
        lcUUID.replaceSubrange(8..<24, with: uuidBytes)

        var cmds = Data()
        cmds.append(segText)
        cmds.append(segData)
        cmds.append(segDataConst)
        cmds.append(lcUUID)
        var ncmds: UInt32 = 4

        if useChainedFixups {
            let fixOff = 0xD000
            putU32(&macho, at: fixOff + 0, 0)
            putU32(&macho, at: fixOff + 4, 0x20)
            let startsImg = fixOff + 0x20
            putU32(&macho, at: startsImg + 0, 3)
            putU32(&macho, at: startsImg + 4, 0)
            putU32(&macho, at: startsImg + 8, 0x14)
            putU32(&macho, at: startsImg + 12, 0)
            let segInfo = startsImg + 0x14
            putU32(&macho, at: segInfo + 0, 24)
            putU16(&macho, at: segInfo + 4, 0x4000)
            putU16(&macho, at: segInfo + 6, 6)
            putU64(&macho, at: segInfo + 8, 0x8000)

            var lcChained = Data(count: 16)
            putU32(&lcChained, at: 0, 0x8000_0034)
            putU32(&lcChained, at: 4, 16)
            putU32(&lcChained, at: 8, UInt32(fixOff))
            putU32(&lcChained, at: 12, 0x100)
            cmds.append(lcChained)
            ncmds += 1
        }

        putU32(&macho, at: 0, 0xfeed_facf)
        putU32(&macho, at: 4, MachOSliceInfo.cpuTypeARM64)
        putU32(&macho, at: 8, 0)
        putU32(&macho, at: 12, 6)
        putU32(&macho, at: 16, ncmds)
        putU32(&macho, at: 20, UInt32(cmds.count))
        macho.replaceSubrange(32..<(32 + cmds.count), with: cmds)

        let expected = IL2CPPOffsetSet(
            sdkInterfaceClassSlot: slotSDKInterface,
            sdkExternalToolsClassSlot: slotSDKExternal,
            sdkMetaClassSlot: slotSDKMeta,
            networkerTypeSlot: slotNetworkerRef,
            networkerExpectedClass: rvaGenericSingletonGetInst,
            gameFlowClassSlot: slotGameFlow,
            getNetworkConfigFn: rvaGetNetConfig,
            overrideNetworkOptionsFn: rvaOverrideNet,
            createStringFn: rvaCreateString,
            internalSDKMetaFn: rvaInternalSDKMeta,
            sdkMetaCtorFn: rvaSDKMetaCtorReal,
            clearAuthStatusFn: rvaClearAuth,
            clearLoginStatusFn: rvaClearLogin,
            getCurrentSceneFn: rvaGetCurrentScene
        )

        return SyntheticIL2CPPFixture(
            unityUUID: uuidStr,
            globalMetadata: meta,
            unityFramework: macho,
            expectedOffsets: expected
        )
    }
}
