import CryptoKit
import Foundation
import IPAPatcherCore
import Zip64Kit

/// Generates valid synthetic Mach-O binaries, kits, and IPAs for unit & parity testing without requiring
/// a real proprietary IPA or closed-source `payload.zip`.
enum SyntheticIPABuilder {
    struct SyntheticKitContext {
        let engine: IPAPatcherEngine
        let profile: TrustedPatchProfile
        let verifiedKits: [VerifiedPatchKit]
        let manifest: PatchKitManifest
    }

    /// Creates a self-contained synthetic patch kit on disk (with valid arm64 Mach-O dylibs,
    /// B-server icon assets, nested bundle resources, and `ABRuntimeProfile.plist`) so the full
    /// test suite runs cleanly on a fresh open-source clone without closed-source `payload.zip`.
    static func createSyntheticKitEngine(in directory: URL) throws -> SyntheticKitContext {
        let kitDir = directory.appendingPathComponent("synthetic-kit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: kitDir, withIntermediateDirectories: true)

        let appRoot = "Payload/Arknights.app/"
        let bridgeData = makeThinMachO64(uuidString: "aaaaaaaa-1111-2222-3333-444444444444")
        let carrierData = makeThinMachO64(uuidString: "bbbbbbbb-1111-2222-3333-444444444444")
        let rtProfile = RuntimeOffsetProfile(
            name: "Synthetic 2.7.91",
            revision: BuiltInKitRepository.activeRevision,
            version: BuiltInKitRepository.activeVersion,
            build: BuiltInKitRepository.activeBuild,
            unityUUID: "386e1e29-f538-38c5-84d3-40427d3e6eb1",
            unityTextSize: nil,
            unityTextSHA256: nil,
            il2cppOffsets: .builtIn2791
        )
        let rtPlistData = try rtProfile.encodeToRuntimeProfilePlistData()

        let entries: [String: Data] = [
            appRoot + "Frameworks/ABLoginBridge.dylib": bridgeData,
            appRoot + "Frameworks/ABSDKCarrier.dylib": carrierData,
            appRoot + "ABRuntimeProfile.plist": rtPlistData,
            appRoot + "ABAppIcon60x60@2x.png": Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02]),
            appRoot + "ABAppIcon60x60@3x.png": Data([0x89, 0x50, 0x4E, 0x47, 0x03, 0x04]),
            appRoot + "BLImages.bundle/bg.png": Data([0x89, 0x50, 0x4E, 0x47, 0x05, 0x06]),
            appRoot + "GSCSDKResources.bundle/Localizable.strings": Data("\"ok\" = \"ok\";\n".utf8),
        ]

        let payloadURL = kitDir.appendingPathComponent("payload.zip")
        let writer = try Zip64Writer(url: payloadURL)
        var payloadEntriesSHA: [String: String] = [:]
        for (name, data) in entries.sorted(by: { $0.key < $1.key }) {
            let mode: UInt32 = name.hasSuffix(".dylib") ? 0o100755 : 0o100644
            try writer.writeDeflatedEntry(name: name, data: data, externalAttributes: mode << 16)
            payloadEntriesSHA[name] = SHA256.hash(data: data).hexString
        }
        try writer.finish()

        let payloadSHA = try FileHasher.sha256Hex(of: payloadURL)
        let hostBinaries: [String: [String: String]] = [
            appRoot + "Arknights": ["uuid": "c0c6e046-81ae-3987-817a-0f1530ab074f"],
            appRoot + "Frameworks/OpenSSL.framework/OpenSSL": ["uuid": "3bec285b-b10d-3071-b247-fc159dc7a070"],
            appRoot + "Frameworks/SSZipArchive.framework/SSZipArchive": ["uuid": "c1e2fe1f-2230-324a-81b4-b9b24b6a7dbf"],
            appRoot + "Frameworks/UnityFramework.framework/UnityFramework": ["uuid": "386e1e29-f538-38c5-84d3-40427d3e6eb1"],
            appRoot + "Frameworks/hpatchz_dynamic.framework/hpatchz_dynamic": ["uuid": "6eaca2b8-c24e-3612-81a2-531ee8bf7040"],
            appRoot + "Frameworks/tersafe2.framework/tersafe2": ["uuid": "07b63fe7-0c49-3607-a978-d47fa3dcaa56"],
        ]

        let manifestObj: [String: Any] = [
            "schema": 1,
            "revision": BuiltInKitRepository.activeRevision,
            "bundle_id": "com.hypergryph.arknights",
            "version": BuiltInKitRepository.activeVersion,
            "build": BuiltInKitRepository.activeBuild,
            "app_root": appRoot,
            "input_hash_allowlist_used": false,
            "host_binaries": hostBinaries,
            "binary_patches": [String: Any](),
            "dynamic_dylib_injection": [
                "target_binary": appRoot + "Frameworks/UnityFramework.framework/UnityFramework",
                "dylib_load_path": "@executable_path/Frameworks/ABLoginBridge.dylib",
            ],
            "payload_sha256": payloadSHA,
            "payload_entries": payloadEntriesSHA,
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifestObj, options: [.sortedKeys])
        let manifestURL = kitDir.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestURL)
        let manifestSHA = SHA256.hash(data: manifestData).hexString

        let profile = BuiltInKitRepository.externalProfile(
            kitDirectory: kitDir,
            revision: BuiltInKitRepository.activeRevision,
            version: BuiltInKitRepository.activeVersion,
            build: BuiltInKitRepository.activeBuild,
            lockedManifestSHA256: manifestSHA
        )
        let engine = IPAPatcherEngine(profiles: [profile])
        let verifiedKits = try engine.verifyConfiguredKits()
        return SyntheticKitContext(
            engine: engine,
            profile: profile,
            verifiedKits: verifiedKits,
            manifest: verifiedKits[0].manifest
        )
    }
    struct Configuration {
        var bundleID: String = "com.hypergryph.arknights"
        var version: String = "2.7.91"
        var build: String = "76"
        var appFolderName: String = "Arknights.app"
        var encryptMainBinary: Bool = false
        var makeFatUnityBinary: Bool = false
        var overrideUnityUUID: String? = nil
        var corruptPreimage: Bool = false
        var preInjectBridge: Bool = false
        var includeStoreSignatures: Bool = true
        var extraResourceBytes: Int = 256 * 1024
    }

    /// Builds a valid 64-bit thin Mach-O binary (`arm64` by default) with `LC_UUID` and `LC_ENCRYPTION_INFO_64`.
    static func makeThinMachO64(
        uuidString: String,
        cpuType: UInt32 = MachOSliceInfo.cpuTypeARM64,
        cryptid: UInt32 = 0,
        targetNcmds: UInt32 = 2,
        targetSizeOfCmds: UInt32 = 48,
        trailingZeroBytes: Int = 128
    ) -> Data {
        precondition(targetNcmds >= 2)
        precondition(targetSizeOfCmds >= 48)
        let remainingCmds = Int(targetNcmds) - 2
        let remainingBytes = Int(targetSizeOfCmds) - 48

        var data = Data()
        // mach_header_64 (32 bytes)
        appendUInt32LE(&data, 0xfeed_facf) // MH_MAGIC_64
        appendUInt32LE(&data, cpuType)
        appendUInt32LE(&data, 0) // cpusubtype
        appendUInt32LE(&data, 2) // MH_EXECUTE
        appendUInt32LE(&data, targetNcmds) // offset 16
        appendUInt32LE(&data, targetSizeOfCmds) // offset 20
        appendUInt32LE(&data, 0) // flags
        appendUInt32LE(&data, 0) // reserved

        // 1. LC_UUID (cmd = 0x1b, cmdsize = 24)
        appendUInt32LE(&data, 0x1b)
        appendUInt32LE(&data, 24)
        let uuid = UUID(uuidString: uuidString)!
        withUnsafeBytes(of: uuid.uuid) { data.append(contentsOf: $0) }

        // 2. LC_ENCRYPTION_INFO_64 (cmd = 0x2c, cmdsize = 24)
        appendUInt32LE(&data, 0x2c)
        appendUInt32LE(&data, 24)
        appendUInt32LE(&data, 0x4000) // cryptoff
        appendUInt32LE(&data, 0x4000) // cryptsize
        appendUInt32LE(&data, cryptid) // cryptid (offset +16)
        appendUInt32LE(&data, 0) // pad

        // Fill any remaining load commands cleanly so `pos == header + sizeofcmds`.
        if remainingCmds > 0 {
            let baseCmdSize = (remainingBytes / remainingCmds) & ~7
            var allocated = 0
            for idx in 0..<remainingCmds {
                let isLast = (idx == remainingCmds - 1)
                let size = isLast ? (remainingBytes - allocated) : max(8, baseCmdSize)
                allocated += size
                appendUInt32LE(&data, 0x31) // dummy LC_NOTE
                appendUInt32LE(&data, UInt32(size))
                data.append(Data(count: size - 8))
            }
        }

        data.append(Data(count: trailingZeroBytes))
        return data
    }

    static func makeFat32(slices: [(cpuType: UInt32, data: Data)]) -> Data {
        var out = Data()
        appendUInt32BE(&out, 0xcafe_babe)
        appendUInt32BE(&out, UInt32(slices.count))

        let headerLen = 8 + slices.count * 20
        var offset = UInt32((headerLen + 0xFFF) & ~0xFFF)
        var sliceOffsets: [UInt32] = []
        for s in slices {
            sliceOffsets.append(offset)
            appendUInt32BE(&out, s.cpuType)
            appendUInt32BE(&out, 0)
            appendUInt32BE(&out, offset)
            appendUInt32BE(&out, UInt32(s.data.count))
            appendUInt32BE(&out, 12)
            offset = UInt32((Int(offset) + s.data.count + 0xFFF) & ~0xFFF)
        }
        for (i, s) in slices.enumerated() {
            let pad = Int(sliceOffsets[i]) - out.count
            if pad > 0 { out.append(Data(count: pad)) }
            out.append(s.data)
        }
        return out
    }

    /// Creates a synthetic IPA matching (or intentionally deviating from) the built-in r3 manifest.
    static func createSyntheticIPA(
        at url: URL,
        manifest: PatchKitManifest,
        config: Configuration = Configuration()
    ) throws {
        let appRoot = "Payload/\(config.appFolderName)/"
        let writer = try Zip64Writer(url: url)

        try writer.writeDirectoryEntry(name: "Payload/")
        try writer.writeDirectoryEntry(name: appRoot)
        try writer.writeDirectoryEntry(name: appRoot + "Frameworks/")

        // Info.plist (including realistic official U8SDK block & host metadata to test dynamic merge)
        let infoDict: [String: Any] = [
            "CFBundleIdentifier": config.bundleID,
            "CFBundleShortVersionString": config.version,
            "CFBundleVersion": config.build,
            "CFBundleDisplayName": "明日方舟",
            "CFBundleExecutable": "Arknights",
            "MinimumOSVersion": "13.0",
            "U8SDK": [
                "AppId": 1,
                "AppKey": "e965bb316534227f7fa8024fe3dc9539",
                "Channel": 1,
                "World": 1,
                "ChannelName": "HG",
                "Plugins": [["className": "HGN"]]
            ]
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: infoDict, format: .xml, options: 0)
        try writer.writeDeflatedEntry(
            name: appRoot + "Info.plist",
            data: infoData,
            externalAttributes: 0o100644 << 16
        )

        // Create all 6 expected host binaries + nested framework Info.plists.
        for (manifestPath, expected) in manifest.hostBinaries.sorted(by: { $0.key < $1.key }) {
            let relativePath = manifestPath.replacingOccurrences(of: manifest.appRoot, with: "")
            let actualPath = appRoot + relativePath
            let isUnity = relativePath.contains("UnityFramework.framework/UnityFramework")
            let isMain = (relativePath == "Arknights")

            // Add framework Info.plist if inside `.framework/`.
            if let range = actualPath.range(of: ".framework/") {
                let fwDir = String(actualPath[..<range.upperBound])
                let fwExec = String(actualPath[range.upperBound...])
                let fwPlist: [String: Any] = [
                    "CFBundleIdentifier": "com.test.\(fwExec)",
                    "CFBundleExecutable": fwExec
                ]
                let fwData = try PropertyListSerialization.data(fromPropertyList: fwPlist, format: .xml, options: 0)
                try writer.writeDeflatedEntry(
                    name: fwDir + "Info.plist",
                    data: fwData,
                    externalAttributes: 0o100644 << 16
                )
            }

            let uuid = (isUnity ? config.overrideUnityUUID : nil) ?? expected.uuid
            let cryptid: UInt32 = (isMain && config.encryptMainBinary) ? 1 : 0

            let binaryData: Data
            if isUnity {
                // Exact r3 UnityFramework header: ncmds=0x61 (97), sizeofcmds=0x2ad8 (10968),
                // so offset 16 holds `61000000d82a0000` and offset 11000 (= 32 + 10968) holds 72 zero bytes!
                var unity = makeThinMachO64(
                    uuidString: uuid,
                    cryptid: cryptid,
                    targetNcmds: 0x61,
                    targetSizeOfCmds: 0x2ad8,
                    trailingZeroBytes: 4096
                )
                if config.corruptPreimage {
                    unity[11000] = 0xAA
                }
                if config.preInjectBridge {
                    unity = try MachODylibInjector.inject(
                        dylibLoadPath: "@executable_path/Frameworks/ABLoginBridge.dylib",
                        into: unity,
                        binaryPath: actualPath
                    ).data
                }
                if config.makeFatUnityBinary {
                    let secondSlice = makeThinMachO64(uuidString: uuid, cpuType: MachOSliceInfo.cpuTypeX86_64)
                    binaryData = makeFat32(slices: [
                        (MachOSliceInfo.cpuTypeARM64, unity),
                        (MachOSliceInfo.cpuTypeX86_64, secondSlice)
                    ])
                } else {
                    binaryData = unity
                }
            } else {
                binaryData = makeThinMachO64(uuidString: uuid, cryptid: cryptid)
            }

            try writer.writeDeflatedEntry(
                name: actualPath,
                data: binaryData,
                externalAttributes: 0o100755 << 16
            )
        }

        // Synthetic plaintext Unity global-metadata.dat (magic 0xFAB11BAF, version 29)
        var metadataHeader = Data()
        appendUInt32LE(&metadataHeader, 0xFAB1_1BAF)
        appendUInt32LE(&metadataHeader, 29)
        metadataHeader.append(Data(count: 256))
        try writer.writeDeflatedEntry(
            name: appRoot + "Data/Managed/Metadata/global-metadata.dat",
            data: metadataHeader,
            externalAttributes: 0o100644 << 16
        )

        // Preserved game asset resource
        var assetData = Data(capacity: config.extraResourceBytes)
        for i in 0..<config.extraResourceBytes {
            assetData.append(UInt8((i &* 17 &+ 3) & 0xFF))
        }
        try writer.writeDeflatedEntry(
            name: appRoot + "Data/sharedassets0.assets",
            data: assetData,
            externalAttributes: 0o100644 << 16
        )

        // Original store/signature entries that must be stripped.
        if config.includeStoreSignatures {
            try writer.writeDeflatedEntry(
                name: "iTunesMetadata.plist",
                data: Data("store".utf8),
                externalAttributes: 0o100644 << 16
            )
            try writer.writeDeflatedEntry(
                name: appRoot + "_CodeSignature/CodeResources",
                data: Data("sig".utf8),
                externalAttributes: 0o100644 << 16
            )
            try writer.writeDeflatedEntry(
                name: appRoot + "SC_Info/Arknights.sinf",
                data: Data("sinf".utf8),
                externalAttributes: 0o100644 << 16
            )
            try writer.writeDeflatedEntry(
                name: appRoot + "embedded.mobileprovision",
                data: Data("prov".utf8),
                externalAttributes: 0o100644 << 16
            )
        }

        try writer.finish()
    }

    private static func appendUInt32LE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func appendUInt32BE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
