import Foundation

/// Universal arm64 Mach-O `LC_LOAD_DYLIB` injector and inspector.
/// Locates free zero-padding between `sizeofcmds` and the first section automatically — no hardcoded offsets required.
public enum MachODylibInjector {
    private static let mhMagic64LE: UInt32 = 0xfeed_facf
    private static let cpuTypeARM64: UInt32 = 0x0100_000c
    private static let lcSegment64: UInt32 = 0x19
    private static let lcLoadDylib: UInt32 = 0x0c
    private static let lcLoadWeakDylib: UInt32 = 0x8000_0018
    private static let lcReexportDylib: UInt32 = 0x8000_001f

    public struct InjectionReport: Sendable, Hashable {
        public let insertOffset: Int
        public let commandSize: Int
        public let previousLoadCommandCount: UInt32
        public let newLoadCommandCount: UInt32
        public let dylibLoadPath: String
    }

    /// Lists all dylib load paths referenced by `LC_LOAD_DYLIB` / `LC_LOAD_WEAK_DYLIB` / `LC_REEXPORT_DYLIB`.
    public static func loadedDylibPaths(in raw: Data, binaryPath: String) throws -> [String] {
        guard raw.count >= 32 else {
            throw PatchError.invalidMachO(binaryPath: binaryPath, reason: "Mach-O 头部不足 32 字节")
        }
        let magic = readUInt32LE(raw, at: 0)
        guard magic == mhMagic64LE else {
            throw PatchError.invalidMachO(binaryPath: binaryPath, reason: "仅支持 64 位单架构 Mach-O")
        }
        let ncmds = Int(readUInt32LE(raw, at: 16))
        let sizeofcmds = Int(readUInt32LE(raw, at: 20))
        let cmdsEnd = 32 + sizeofcmds
        guard cmdsEnd <= raw.count else {
            throw PatchError.invalidMachO(binaryPath: binaryPath, reason: "Load Commands 超出文件范围")
        }

        var cursor = 32
        var paths: [String] = []
        for _ in 0..<ncmds {
            guard cursor + 8 <= cmdsEnd else { break }
            let cmd = readUInt32LE(raw, at: cursor)
            let cmdsize = Int(readUInt32LE(raw, at: cursor + 4))
            guard cmdsize >= 8 && cursor + cmdsize <= cmdsEnd else {
                throw PatchError.invalidMachO(binaryPath: binaryPath, reason: "Load Command 大小无效")
            }
            if (cmd == lcLoadDylib || cmd == lcLoadWeakDylib || cmd == lcReexportDylib), cmdsize >= 24 {
                let nameOffset = Int(readUInt32LE(raw, at: cursor + 8))
                if nameOffset >= 24 && nameOffset < cmdsize {
                    let strStart = raw.startIndex + cursor + nameOffset
                    let strEnd = raw.startIndex + cursor + cmdsize
                    let slice = raw[strStart..<strEnd]
                    let trimmed = slice.prefix(while: { $0 != 0 })
                    if let path = String(bytes: trimmed, encoding: .utf8) {
                        paths.append(path)
                    }
                }
            }
            cursor += cmdsize
        }
        return paths
    }

    /// Dynamically injects `LC_LOAD_DYLIB` into an arm64 64-bit Mach-O binary by finding free zero-padded header space.
    /// Refuses cleanly if the dylib (or same basename) is already loaded.
    public static func inject(
        dylibLoadPath: String,
        into raw: Data,
        binaryPath: String
    ) throws -> (data: Data, report: InjectionReport) {
        guard raw.count >= 32 else {
            throw PatchError.machOInjectionFailed(binaryPath: binaryPath, reason: "Mach-O 头部不足 32 字节")
        }
        let magic = readUInt32LE(raw, at: 0)
        let cpuType = readUInt32LE(raw, at: 4)
        guard magic == mhMagic64LE, cpuType == cpuTypeARM64 else {
            throw PatchError.machOInjectionFailed(binaryPath: binaryPath, reason: "目标二进制不是单架构 arm64 Mach-O")
        }

        let ncmds = readUInt32LE(raw, at: 16)
        let sizeofcmds = readUInt32LE(raw, at: 20)
        let insertOffset = 32 + Int(sizeofcmds)
        guard insertOffset <= raw.count else {
            throw PatchError.machOInjectionFailed(binaryPath: binaryPath, reason: "Load Commands 越界")
        }

        // Walk existing load commands: check for duplicate injection and find earliest non-empty section offset.
        let targetBasename = URL(fileURLWithPath: dylibLoadPath).lastPathComponent
        var cursor = 32
        var minSectionOffset = raw.count

        for _ in 0..<Int(ncmds) {
            guard cursor + 8 <= insertOffset else {
                throw PatchError.machOInjectionFailed(binaryPath: binaryPath, reason: "Load Command 头部被截断")
            }
            let cmd = readUInt32LE(raw, at: cursor)
            let cmdsize = Int(readUInt32LE(raw, at: cursor + 4))
            guard cmdsize >= 8 && cursor + cmdsize <= insertOffset else {
                throw PatchError.machOInjectionFailed(binaryPath: binaryPath, reason: "Load Command 长度异常")
            }

            if (cmd == lcLoadDylib || cmd == lcLoadWeakDylib || cmd == lcReexportDylib), cmdsize >= 24 {
                let nameOffset = Int(readUInt32LE(raw, at: cursor + 8))
                if nameOffset >= 24 && nameOffset < cmdsize {
                    let s = raw.startIndex + cursor + nameOffset
                    let e = raw.startIndex + cursor + cmdsize
                    if let existingPath = String(bytes: raw[s..<e].prefix(while: { $0 != 0 }), encoding: .utf8) {
                        if existingPath == dylibLoadPath
                            || URL(fileURLWithPath: existingPath).lastPathComponent == targetBasename {
                            throw PatchError.alreadyInjected(binaryPath: binaryPath, dylibPath: existingPath)
                        }
                    }
                }
            } else if cmd == lcSegment64 && cmdsize >= 72 {
                let nsects = Int(readUInt32LE(raw, at: cursor + 64))
                let sectBase = cursor + 72
                if sectBase + nsects * 80 <= cursor + cmdsize {
                    for j in 0..<nsects {
                        let sOff = sectBase + j * 80
                        let sectSize = readUInt64LE(raw, at: sOff + 40)
                        let fileOffset = Int(readUInt32LE(raw, at: sOff + 48))
                        if sectSize > 0 && fileOffset > 0 && fileOffset < minSectionOffset {
                            minSectionOffset = fileOffset
                        }
                    }
                }
            }

            cursor += cmdsize
        }

        guard cursor == insertOffset else {
            throw PatchError.machOInjectionFailed(binaryPath: binaryPath, reason: "Load Command 结束偏移与 sizeofcmds 不一致")
        }

        // Build 8-byte aligned LC_LOAD_DYLIB command matching exact Apple/baseline binary format.
        let pathUTF8 = Array(dylibLoadPath.utf8)
        let rawLen = 24 + pathUTF8.count + 1
        let cmdSize = (rawLen + 7) & ~7

        guard insertOffset + cmdSize <= minSectionOffset, insertOffset + cmdSize <= raw.count else {
            throw PatchError.machOInjectionFailed(
                binaryPath: binaryPath,
                reason: "Mach-O 头部剩余空隙不足（需要 \(cmdSize) 字节，可用 \(max(0, minSectionOffset - insertOffset)) 字节）"
            )
        }

        // Confirm target gap is completely zero-padded so we never overwrite real code/data.
        let gapStart = raw.startIndex + insertOffset
        let gapEnd = gapStart + cmdSize
        if raw[gapStart..<gapEnd].contains(where: { $0 != 0 }) {
            throw PatchError.machOInjectionFailed(
                binaryPath: binaryPath,
                reason: "偏移 0x\(String(insertOffset, radix: 16)) 处头部空隙非全零，已拒绝写入以防损坏二进制"
            )
        }

        var command = Data()
        command.reserveCapacity(cmdSize)
        appendUInt32LE(&command, lcLoadDylib)        // cmd = LC_LOAD_DYLIB (0x0c)
        appendUInt32LE(&command, UInt32(cmdSize))    // cmdsize (72 for ABLoginBridge.dylib)
        appendUInt32LE(&command, 24)                 // dylib.name.offset
        appendUInt32LE(&command, 0)                  // dylib.timestamp
        appendUInt32LE(&command, 0x0001_0000)        // dylib.current_version (1.0.0)
        appendUInt32LE(&command, 0x0001_0000)        // dylib.compatibility_version (1.0.0)
        command.append(contentsOf: pathUTF8)
        command.append(contentsOf: repeatElement(UInt8(0), count: cmdSize - 24 - pathUTF8.count))

        var edited = raw
        let newNcmds = ncmds + 1
        let newSizeofcmds = sizeofcmds + UInt32(cmdSize)
        var headerPatch = Data()
        appendUInt32LE(&headerPatch, newNcmds)
        appendUInt32LE(&headerPatch, newSizeofcmds)

        let hStart = edited.startIndex + 16
        edited.replaceSubrange(hStart..<(hStart + 8), with: headerPatch)
        let cStart = edited.startIndex + insertOffset
        edited.replaceSubrange(cStart..<(cStart + cmdSize), with: command)

        let report = InjectionReport(
            insertOffset: insertOffset,
            commandSize: cmdSize,
            previousLoadCommandCount: ncmds,
            newLoadCommandCount: newNcmds,
            dylibLoadPath: dylibLoadPath
        )
        return (edited, report)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }

    private static func readUInt64LE(_ data: Data, at offset: Int) -> UInt64 {
        let lo = UInt64(readUInt32LE(data, at: offset))
        let hi = UInt64(readUInt32LE(data, at: offset + 4))
        return lo | (hi << 32)
    }

    private static func appendUInt32LE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}
