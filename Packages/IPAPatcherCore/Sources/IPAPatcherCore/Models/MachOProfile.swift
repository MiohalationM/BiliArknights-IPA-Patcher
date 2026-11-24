import CryptoKit
import Foundation

public struct MachOSliceInfo: Sendable, Hashable, Codable {
    public static let cpuTypeARM64: UInt32 = 0x0100_000c
    public static let cpuTypeARM: UInt32 = 12
    public static let cpuTypeX86_64: UInt32 = 0x0100_0007

    public let cpuType: UInt32
    public let cpuSubtype: UInt32
    public let uuid: String?
    public let cryptids: [UInt32]
    public let size: Int
    public let sha256: String?

    public var isEncrypted: Bool {
        cryptids.contains { $0 != 0 }
    }

    public var architectureName: String {
        switch cpuType {
        case Self.cpuTypeARM64:
            let maskedSub = cpuSubtype & 0x00FF_FFFF
            return maskedSub == 2 ? "arm64e" : "arm64"
        case Self.cpuTypeARM:
            return "armv7"
        case Self.cpuTypeX86_64:
            return "x86_64"
        default:
            return String(format: "cpu(0x%x)", cpuType)
        }
    }

    public init(
        cpuType: UInt32,
        cpuSubtype: UInt32,
        uuid: String?,
        cryptids: [UInt32],
        size: Int,
        sha256: String?
    ) {
        self.cpuType = cpuType
        self.cpuSubtype = cpuSubtype
        self.uuid = uuid
        self.cryptids = cryptids
        self.size = size
        self.sha256 = sha256
    }
}

public enum MachOParser {
    private static let fatMagic32: UInt32 = 0xcafe_babe // big-endian bytes CA FE BA BE
    private static let fatMagic64: UInt32 = 0xcafe_babf // big-endian bytes CA FE BA BF
    private static let mhMagic64LE: UInt32 = 0xfeed_facf // file bytes CF FA ED FE
    private static let mhMagic32LE: UInt32 = 0xfeed_face // file bytes CE FA ED FE

    private static let lcUUID: UInt32 = 0x1b
    private static let lcEncryptionInfo: UInt32 = 0x21
    private static let lcEncryptionInfo64: UInt32 = 0x2c

    /// Inspects every Mach-O slice (Fat32, Fat64, Thin64, Thin32).
    /// Matches Python `macho_slices` strictly; does not treat `cryptid == 0` alone as proof of valid plaintext.
    public static func parseSlices(
        data: Data,
        binaryPath: String,
        includeSHA256: Bool = false
    ) throws -> [MachOSliceInfo] {
        try parseSlices(data: data, binaryPath: binaryPath, includeSHA256: includeSHA256, allowFat: true)
    }

    private static func parseSlices(
        data: Data,
        binaryPath: String,
        includeSHA256: Bool,
        allowFat: Bool
    ) throws -> [MachOSliceInfo] {
        guard data.count >= 8 else {
            throw PatchError.invalidMachO(binaryPath: binaryPath, reason: "Mach-O 文件被截断（不足 8 字节）")
        }

        let magicBE = readUInt32BE(data, at: 0)
        if magicBE == fatMagic32 || magicBE == fatMagic64 {
            guard allowFat else {
                throw PatchError.invalidMachO(binaryPath: binaryPath, reason: "不支持嵌套的 Fat Mach-O 切片")
            }
            let isFat64 = (magicBE == fatMagic64)
            let archCount = Int(readUInt32BE(data, at: 4))
            guard archCount > 0 && archCount < 32 else {
                throw PatchError.invalidMachO(binaryPath: binaryPath, reason: "无效的 Fat 架构数量：\(archCount)")
            }
            let entrySize = isFat64 ? 32 : 20
            var results: [MachOSliceInfo] = []
            results.reserveCapacity(archCount)

            for i in 0..<archCount {
                let pos = 8 + i * entrySize
                guard pos + entrySize <= data.count else {
                    throw PatchError.invalidMachO(binaryPath: binaryPath, reason: "Fat 头被截断")
                }
                let sliceOffset: UInt64
                let sliceSize: UInt64
                if isFat64 {
                    sliceOffset = readUInt64BE(data, at: pos + 8)
                    sliceSize = readUInt64BE(data, at: pos + 16)
                } else {
                    sliceOffset = UInt64(readUInt32BE(data, at: pos + 8))
                    sliceSize = UInt64(readUInt32BE(data, at: pos + 12))
                }
                guard sliceOffset <= UInt64(data.count), sliceSize <= UInt64(data.count) - sliceOffset else {
                    throw PatchError.invalidMachO(binaryPath: binaryPath, reason: "Fat 架构切片范围越界")
                }
                let start = data.startIndex + Int(sliceOffset)
                let end = start + Int(sliceSize)
                let sliceData = data[start..<end]
                results.append(contentsOf: try parseSlices(data: sliceData, binaryPath: binaryPath, includeSHA256: includeSHA256, allowFat: false))
            }
            return results
        }

        let magicLE = readUInt32LE(data, at: 0)
        guard magicLE == mhMagic64LE || magicLE == mhMagic32LE else {
            throw PatchError.invalidMachO(
                binaryPath: binaryPath,
                reason: String(format: "不支持的可执行文件魔数（0x%08x）", magicBE)
            )
        }

        let is64 = (magicLE == mhMagic64LE)
        let headerSize = is64 ? 32 : 28
        guard data.count >= headerSize else {
            throw PatchError.invalidMachO(binaryPath: binaryPath, reason: "Mach-O 头被截断")
        }

        let cpuType = readUInt32LE(data, at: 4)
        let cpuSubtype = readUInt32LE(data, at: 8)
        let ncmds = Int(readUInt32LE(data, at: 16))
        let sizeofcmds = Int(readUInt32LE(data, at: 20))

        guard headerSize + sizeofcmds <= data.count && ncmds <= sizeofcmds / 8 else {
            throw PatchError.invalidMachO(binaryPath: binaryPath, reason: "Mach-O Load Commands 区域无效")
        }

        var cursor = headerSize
        let cmdsEnd = headerSize + sizeofcmds
        var uuidString: String?
        var cryptids: [UInt32] = []

        for _ in 0..<ncmds {
            guard cursor + 8 <= cmdsEnd else {
                throw PatchError.invalidMachO(binaryPath: binaryPath, reason: "Load Command 头被截断")
            }
            let cmd = readUInt32LE(data, at: cursor)
            let cmdsize = Int(readUInt32LE(data, at: cursor + 4))
            guard cmdsize >= 8 && cursor + cmdsize <= cmdsEnd else {
                throw PatchError.invalidMachO(binaryPath: binaryPath, reason: "Load Command 大小无效（\(cmdsize)）")
            }

            if cmd == lcUUID {
                guard cmdsize >= 24 else {
                    throw PatchError.invalidMachO(binaryPath: binaryPath, reason: "LC_UUID 命令长度不足")
                }
                let uStart = data.startIndex + cursor + 8
                let bytes = Array(data[uStart..<(uStart + 16)])
                let uuid = UUID(uuid: (
                    bytes[0], bytes[1], bytes[2], bytes[3],
                    bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11],
                    bytes[12], bytes[13], bytes[14], bytes[15]
                ))
                uuidString = uuid.uuidString.lowercased()
            } else if cmd == lcEncryptionInfo || cmd == lcEncryptionInfo64 {
                guard cmdsize >= 20 else {
                    throw PatchError.invalidMachO(binaryPath: binaryPath, reason: "LC_ENCRYPTION_INFO 命令长度不足")
                }
                let cryptid = readUInt32LE(data, at: cursor + 16)
                cryptids.append(cryptid)
            }

            cursor += cmdsize
        }

        guard cursor == cmdsEnd else {
            throw PatchError.invalidMachO(binaryPath: binaryPath, reason: "Load Command 总长度与头部声明不一致")
        }

        let digestHex: String?
        if includeSHA256 {
            digestHex = SHA256.hash(data: data).hexString
        } else {
            digestHex = nil
        }

        return [
            MachOSliceInfo(
                cpuType: cpuType,
                cpuSubtype: cpuSubtype,
                uuid: uuidString,
                cryptids: cryptids,
                size: data.count,
                sha256: digestHex
            )
        ]
    }

    /// Computes the exact `__TEXT.__text` section size and SHA-256 hex digest of a 64-bit thin Mach-O binary,
    /// matching `ABCheckUnityImage` in `Bridge/Sources/ABHooks.m`.
    public static func extractPrimaryTextDigest(data: Data) -> (size: UInt64, sha256: String)? {
        guard data.count >= 32, readUInt32LE(data, at: 0) == mhMagic64LE else { return nil }
        let ncmds = Int(readUInt32LE(data, at: 16))
        let sizeofcmds = Int(readUInt32LE(data, at: 20))
        let cmdsEnd = 32 + sizeofcmds
        guard cmdsEnd <= data.count else { return nil }

        let lcSegment64: UInt32 = 0x19
        var cursor = 32
        var found: (size: UInt64, sha256: String)?

        for _ in 0..<ncmds {
            guard cursor + 8 <= cmdsEnd else { return nil }
            let cmd = readUInt32LE(data, at: cursor)
            let cmdsize = Int(readUInt32LE(data, at: cursor + 4))
            guard cmdsize >= 8 && cursor + cmdsize <= cmdsEnd else { return nil }

            if cmd == lcSegment64 && cmdsize >= 72 {
                let nsects = Int(readUInt32LE(data, at: cursor + 64))
                var secPos = cursor + 72
                for _ in 0..<nsects {
                    guard secPos + 80 <= cursor + cmdsize else { return nil }
                    let sectName = readFixedCString(data, at: secPos, maxLength: 16)
                    let segName = readFixedCString(data, at: secPos + 16, maxLength: 16)
                    if sectName == "__text" && segName == "__TEXT" {
                        if found != nil { return nil } // duplicate __TEXT.__text rejected just like ABHooks.m
                        let secSize = readUInt64LE(data, at: secPos + 40)
                        let secOffset = UInt64(readUInt32LE(data, at: secPos + 48))
                        guard secOffset <= UInt64(data.count), secSize <= UInt64(data.count) - secOffset else {
                            return nil
                        }
                        let start = data.startIndex + Int(secOffset)
                        let end = start + Int(secSize)
                        found = (secSize, SHA256.hash(data: data[start..<end]).hexString)
                    }
                    secPos += 80
                }
            }
            cursor += cmdsize
        }

        return cursor == cmdsEnd ? found : nil
    }

    /// Validates that a `RuntimeOffsetProfile`'s 14 RVAs satisfy ARM64 alignment and, whenever the target
    /// Mach-O declares `LC_SEGMENT_64` segments, fall within the corresponding executable/data RVA ranges.
    public static func validateRuntimeOffsets(
        _ offsets: IL2CPPOffsetSet,
        againstMachOData data: Data
    ) -> [CompatibilityMismatch] {
        var mismatches: [CompatibilityMismatch] = []

        let codeTargets: [(key: String, rva: UInt64, optionalZero: Bool)] = [
            ("getNetworkConfigFn", offsets.getNetworkConfigFn, false),
            ("overrideNetworkOptionsFn", offsets.overrideNetworkOptionsFn, false),
            ("createStringFn", offsets.createStringFn, false),
            ("internalSDKMetaFn", offsets.internalSDKMetaFn, false),
            ("sdkMetaCtorFn", offsets.sdkMetaCtorFn, false),
            ("clearAuthStatusFn", offsets.clearAuthStatusFn, false),
            ("clearLoginStatusFn", offsets.clearLoginStatusFn, false),
            ("getCurrentSceneFn", offsets.getCurrentSceneFn, false),
            ("networkerExpectedClass", offsets.networkerExpectedClass, true),
        ]
        let dataSlotTargets: [(key: String, rva: UInt64)] = [
            ("sdkInterfaceClassSlot", offsets.sdkInterfaceClassSlot),
            ("sdkExternalToolsClassSlot", offsets.sdkExternalToolsClassSlot),
            ("sdkMetaClassSlot", offsets.sdkMetaClassSlot),
            ("networkerTypeSlot", offsets.networkerTypeSlot),
            ("gameFlowClassSlot", offsets.gameFlowClassSlot),
        ]

        // 1. ARM64 instruction (4-byte) and pointer slot (8-byte) alignment checks.
        for item in codeTargets {
            if item.optionalZero && item.rva == 0 { continue }
            if item.rva == 0 || (item.rva & 3) != 0 {
                mismatches.append(
                    CompatibilityMismatch(
                        kind: .binaryTextDigest,
                        fieldLabel: "函数偏移对齐 · \(item.key)",
                        expected: "非零且 4 字节对齐的 ARM64 代码偏移",
                        actual: IL2CPPOffsetSet.hexString(item.rva),
                        detail: "手工配置中的函数地址 \(item.key) 未按 ARM64 指令 4 字节对齐，运行时直接调用会导致闪退。"
                    )
                )
            }
        }
        for item in dataSlotTargets {
            if item.rva == 0 || (item.rva & 7) != 0 {
                mismatches.append(
                    CompatibilityMismatch(
                        kind: .binaryTextDigest,
                        fieldLabel: "数据槽位对齐 · \(item.key)",
                        expected: "非零且 8 字节对齐的指针槽位偏移",
                        actual: IL2CPPOffsetSet.hexString(item.rva),
                        detail: "手工配置中的数据槽位 \(item.key) 未按 64 位指针 8 字节对齐，无法指向合法全局槽位。"
                    )
                )
            }
        }

        // 2. Segment RVA bounds check when the Mach-O declares `LC_SEGMENT_64` commands.
        guard data.count >= 32, readUInt32LE(data, at: 0) == mhMagic64LE else { return mismatches }
        let ncmds = Int(readUInt32LE(data, at: 16))
        let sizeofcmds = Int(readUInt32LE(data, at: 20))
        let cmdsEnd = 32 + sizeofcmds
        guard cmdsEnd <= data.count else { return mismatches }

        struct RawSegment {
            let name: String
            let vmaddr: UInt64
            let vmsize: UInt64
            let initprot: UInt32
            let textSectionRange: (start: UInt64, end: UInt64)?
        }

        let lcSegment64: UInt32 = 0x19
        let vmProtRead: UInt32 = 0x1
        let vmProtExec: UInt32 = 0x4
        var cursor = 32
        var segments: [RawSegment] = []
        var textBaseVMAddr: UInt64?

        for _ in 0..<ncmds {
            guard cursor + 8 <= cmdsEnd else { break }
            let cmd = readUInt32LE(data, at: cursor)
            let cmdsize = Int(readUInt32LE(data, at: cursor + 4))
            guard cmdsize >= 8 && cursor + cmdsize <= cmdsEnd else { break }
            if cmd == lcSegment64 && cmdsize >= 72 {
                let segName = readFixedCString(data, at: cursor + 8, maxLength: 16)
                let vmaddr = readUInt64LE(data, at: cursor + 24)
                let vmsize = readUInt64LE(data, at: cursor + 32)
                let initprot = readUInt32LE(data, at: cursor + 60)
                let nsects = Int(readUInt32LE(data, at: cursor + 64))
                var textSecRange: (UInt64, UInt64)?
                if segName == "__TEXT" {
                    textBaseVMAddr = vmaddr
                    var secPos = cursor + 72
                    for _ in 0..<nsects where secPos + 80 <= cursor + cmdsize {
                        let sName = readFixedCString(data, at: secPos, maxLength: 16)
                        if sName == "__text" {
                            let sAddr = readUInt64LE(data, at: secPos + 32)
                            let sSize = readUInt64LE(data, at: secPos + 40)
                            if sAddr >= vmaddr && sSize > 0 {
                                textSecRange = (sAddr - vmaddr, (sAddr - vmaddr) &+ sSize)
                            }
                        }
                        secPos += 80
                    }
                }
                if vmsize > 0 && segName != "__PAGEZERO" {
                    segments.append(
                        RawSegment(
                            name: segName,
                            vmaddr: vmaddr,
                            vmsize: vmsize,
                            initprot: initprot,
                            textSectionRange: textSecRange
                        )
                    )
                }
            }
            cursor += cmdsize
        }

        guard let baseVM = textBaseVMAddr, !segments.isEmpty else {
            return mismatches
        }

        var codeRanges: [(start: UInt64, end: UInt64)] = []
        var dataRanges: [(start: UInt64, end: UInt64)] = []
        for seg in segments where seg.vmaddr >= baseVM {
            let rvaStart = seg.vmaddr - baseVM
            let rvaEnd = rvaStart &+ seg.vmsize
            if let textSec = seg.textSectionRange {
                codeRanges.append(textSec)
            } else if (seg.initprot & vmProtExec) != 0 || seg.name == "__TEXT" {
                codeRanges.append((rvaStart, rvaEnd))
            } else if seg.name != "__LINKEDIT" && seg.name != "__TEXT" && (
                (seg.initprot & vmProtRead) != 0 ||
                seg.name.hasPrefix("__DATA") ||
                seg.name.hasPrefix("__AUTH")
            ) {
                dataRanges.append((rvaStart, rvaEnd))
            }
        }

        if !codeRanges.isEmpty {
            let codeSummary = codeRanges
                .map { "\(IL2CPPOffsetSet.hexString($0.start))..<\(IL2CPPOffsetSet.hexString($0.end))" }
                .joined(separator: ", ")
            for item in codeTargets {
                if item.optionalZero && item.rva == 0 { continue }
                if (item.rva & 3) != 0 { continue } // already reported alignment error
                let inCode = codeRanges.contains { item.rva >= $0.start && item.rva &+ 4 <= $0.end }
                if !inCode {
                    mismatches.append(
                        CompatibilityMismatch(
                            kind: .binaryTextDigest,
                            fieldLabel: "函数偏移越界 · \(item.key)",
                            expected: "位于可执行代码段（\(codeSummary)）",
                            actual: IL2CPPOffsetSet.hexString(item.rva),
                            detail: "配置文件中的函数偏移 \(item.key) 未落入 UnityFramework 可执行代码段，继续导出会导致游戏运行时闪退。"
                        )
                    )
                }
            }
        }

        if !dataRanges.isEmpty {
            let dataSummary = dataRanges
                .map { "\(IL2CPPOffsetSet.hexString($0.start))..<\(IL2CPPOffsetSet.hexString($0.end))" }
                .joined(separator: ", ")
            for item in dataSlotTargets {
                if (item.rva & 7) != 0 { continue } // already reported alignment error
                let inData = dataRanges.contains { item.rva >= $0.start && item.rva &+ 8 <= $0.end }
                if !inData {
                    mismatches.append(
                        CompatibilityMismatch(
                            kind: .binaryTextDigest,
                            fieldLabel: "数据槽位越界 · \(item.key)",
                            expected: "位于已映射数据段（\(dataSummary)）",
                            actual: IL2CPPOffsetSet.hexString(item.rva),
                            detail: "配置文件中的全局槽位偏移 \(item.key) 未落入 UnityFramework 数据段，继续导出会导致运行时读到无效地址。"
                        )
                    )
                }
            }
        }

        return mismatches
    }

    private static func readFixedCString(_ data: Data, at offset: Int, maxLength: Int) -> String {
        let start = data.startIndex + offset
        var len = 0
        while len < maxLength && data[start + len] != 0 {
            len += 1
        }
        return String(decoding: data[start..<(start + len)], as: UTF8.self)
    }

    private static func readUInt64LE(_ data: Data, at offset: Int) -> UInt64 {
        let lo = UInt64(readUInt32LE(data, at: offset))
        let hi = UInt64(readUInt32LE(data, at: offset + 4))
        return lo | (hi << 32)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return (UInt32(data[i]) << 24)
            | (UInt32(data[i + 1]) << 16)
            | (UInt32(data[i + 2]) << 8)
            | UInt32(data[i + 3])
    }

    private static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64 {
        let high = UInt64(readUInt32BE(data, at: offset))
        let low = UInt64(readUInt32BE(data, at: offset + 4))
        return (high << 32) | low
    }
}

public extension SHA256Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
