import Foundation
import Zip64Kit

/// Lightweight probe collected during Host Identification to guide pure on-device adaptation
/// for future game versions without needing a computer or a second IPA.
public struct IL2CPPProbeSummary: Sendable, Hashable, Codable {
    public let hasGlobalMetadata: Bool
    public let globalMetadataBytes: UInt64?
    public let globalMetadataMagicHex: String?
    public let globalMetadataIsPlaintext: Bool
    public let globalMetadataVersion: UInt32?
    public let unityExportsIL2CPPSymbols: Bool
    public let detectedInjectedBridge: Bool

    public var autoAdaptationHint: String {
        if unityExportsIL2CPPSymbols {
            return "UnityFramework 导出了 il2cpp_* 符号（可支持纯运行时零偏移定位）"
        }
        if hasGlobalMetadata && globalMetadataIsPlaintext {
            let ver = globalMetadataVersion.map { "v\($0)" } ?? "未知版本"
            return "global-metadata.dat 为明文标准格式（\(ver)），支持纯手机单 IPA 静态解析"
        }
        if hasGlobalMetadata {
            let magic = globalMetadataMagicHex ?? "未知"
            return "global-metadata.dat 头部魔数为 \(magic)（可能已加密/自定义），后续需走二进制特征扫描"
        }
        return "未检测到标准 Unity IL2CPP 元数据"
    }

    public init(
        hasGlobalMetadata: Bool,
        globalMetadataBytes: UInt64?,
        globalMetadataMagicHex: String?,
        globalMetadataIsPlaintext: Bool,
        globalMetadataVersion: UInt32?,
        unityExportsIL2CPPSymbols: Bool,
        detectedInjectedBridge: Bool
    ) {
        self.hasGlobalMetadata = hasGlobalMetadata
        self.globalMetadataBytes = globalMetadataBytes
        self.globalMetadataMagicHex = globalMetadataMagicHex
        self.globalMetadataIsPlaintext = globalMetadataIsPlaintext
        self.globalMetadataVersion = globalMetadataVersion
        self.unityExportsIL2CPPSymbols = unityExportsIL2CPPSymbols
        self.detectedInjectedBridge = detectedInjectedBridge
    }
}

public enum IL2CPPProbe {
    private static let standardMetadataMagicLE: UInt32 = 0xFAB1_1BAF
    private static let mhMagic64LE: UInt32 = 0xfeed_facf
    private static let lcSymtab: UInt32 = 0x02
    private static let lcDyldInfo: UInt32 = 0x22
    private static let lcDyldInfoOnly: UInt32 = 0x8000_0022
    private static let lcDyldExportsTrie: UInt32 = 0x8000_0033

    public static func inspect(
        reader: Zip64Reader,
        appRoot: String,
        unityBinaryData: Data?
    ) -> IL2CPPProbeSummary {
        let metadataPath = appRoot + "Data/Managed/Metadata/global-metadata.dat"
        var hasMetadata = false
        var metadataBytes: UInt64?
        var magicHex: String?
        var isPlaintext = false
        var metadataVersion: UInt32?

        if let metaEntry = reader.entry(named: metadataPath) {
            hasMetadata = true
            metadataBytes = metaEntry.uncompressedSize
            if let prefix = try? reader.readDecompressedPrefix(for: metaEntry, prefixBytes: 16), prefix.count >= 8 {
                let magic = readUInt32LE(prefix, at: 0)
                let version = readUInt32LE(prefix, at: 4)
                magicHex = String(format: "0x%08X", magic)
                isPlaintext = (magic == standardMetadataMagicLE)
                if isPlaintext {
                    metadataVersion = version
                }
            }
        }

        var exportsIL2CPP = false
        var alreadyInjected = false
        if let unityData = unityBinaryData {
            exportsIL2CPP = detectsIL2CPPExports(in: unityData)
            if let dylibs = try? MachODylibInjector.loadedDylibPaths(in: unityData, binaryPath: "UnityFramework") {
                alreadyInjected = dylibs.contains { $0.contains("ABLoginBridge.dylib") }
            }
        }

        return IL2CPPProbeSummary(
            hasGlobalMetadata: hasMetadata,
            globalMetadataBytes: metadataBytes,
            globalMetadataMagicHex: magicHex,
            globalMetadataIsPlaintext: isPlaintext,
            globalMetadataVersion: metadataVersion,
            unityExportsIL2CPPSymbols: exportsIL2CPP,
            detectedInjectedBridge: alreadyInjected
        )
    }

    /// Scans Mach-O export trie or symtab string table for `il2cpp_domain_get`.
    private static func detectsIL2CPPExports(in raw: Data) -> Bool {
        guard raw.count >= 32, readUInt32LE(raw, at: 0) == mhMagic64LE else { return false }
        let ncmds = Int(readUInt32LE(raw, at: 16))
        let sizeofcmds = Int(readUInt32LE(raw, at: 20))
        let cmdsEnd = 32 + sizeofcmds
        guard cmdsEnd <= raw.count else { return false }

        let needle = Data("il2cpp_domain_get".utf8)
        var cursor = 32
        for _ in 0..<ncmds {
            guard cursor + 8 <= cmdsEnd else { break }
            let cmd = readUInt32LE(raw, at: cursor)
            let cmdsize = Int(readUInt32LE(raw, at: cursor + 4))
            guard cmdsize >= 8 && cursor + cmdsize <= cmdsEnd else { break }

            if cmd == lcDyldExportsTrie && cmdsize >= 16 {
                let off = Int(readUInt32LE(raw, at: cursor + 8))
                let size = Int(readUInt32LE(raw, at: cursor + 12))
                if off > 0 && size > 0 && off + size <= raw.count {
                    let region = raw[(raw.startIndex + off)..<(raw.startIndex + off + size)]
                    if region.range(of: needle) != nil { return true }
                }
            } else if (cmd == lcDyldInfo || cmd == lcDyldInfoOnly) && cmdsize >= 48 {
                let off = Int(readUInt32LE(raw, at: cursor + 40))
                let size = Int(readUInt32LE(raw, at: cursor + 44))
                if off > 0 && size > 0 && off + size <= raw.count {
                    let region = raw[(raw.startIndex + off)..<(raw.startIndex + off + size)]
                    if region.range(of: needle) != nil { return true }
                }
            } else if cmd == lcSymtab && cmdsize >= 24 {
                let stroff = Int(readUInt32LE(raw, at: cursor + 16))
                let strsize = Int(readUInt32LE(raw, at: cursor + 20))
                if stroff > 0 && strsize > 0 && stroff + strsize <= raw.count {
                    let region = raw[(raw.startIndex + stroff)..<(raw.startIndex + stroff + strsize)]
                    if region.range(of: needle) != nil { return true }
                }
            }
            cursor += cmdsize
        }
        return false
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }
}
