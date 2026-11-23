import Darwin
import Foundation
import zlib

/// Thread-safe, random-access ZIP/ZIP64 reader backed by POSIX `pread` and system `zlib`.
/// Validates path safety and duplicate entries immediately on open.
public final class Zip64Reader: @unchecked Sendable {
    public let url: URL
    public let fileSize: UInt64
    public let entries: [ZipEntry]
    private let entryMap: [String: ZipEntry]
    private let fd: Int32

    public init(url: URL) throws {
        self.url = url
        let openedFD = open(url.path, O_RDONLY)
        guard openedFD >= 0 else {
            let errStr = String(cString: strerror(errno))
            throw ZipError.ioError("无法打开文件 \(url.lastPathComponent)：\(errStr)")
        }

        var st = stat()
        guard fstat(openedFD, &st) == 0 else {
            let errStr = String(cString: strerror(errno))
            close(openedFD)
            throw ZipError.ioError("无法读取文件信息 \(url.lastPathComponent)：\(errStr)")
        }
        guard st.st_size >= 22 else {
            close(openedFD)
            throw ZipError.truncatedArchive("文件过小，不是有效的 ZIP 文件")
        }

        self.fd = openedFD
        self.fileSize = UInt64(st.st_size)

        do {
            let parsed = try Self.parseCentralDirectory(fd: openedFD, fileSize: UInt64(st.st_size))
            try ZipPathValidator.validate(names: parsed.map(\.name))
            self.entries = parsed
            var map: [String: ZipEntry] = [:]
            map.reserveCapacity(parsed.count)
            for entry in parsed {
                map[entry.name] = entry
            }
            self.entryMap = map
        } catch {
            close(openedFD)
            throw error
        }
    }

    deinit {
        close(fd)
    }

    public func entry(named name: String) -> ZipEntry? {
        entryMap[name]
    }

    public var entryNames: [String] {
        entries.map(\.name)
    }

    /// Reads an entire entry into memory (use for metadata, Mach-O binaries, and small payload files).
    public func readData(for entry: ZipEntry, maxBytes: UInt64 = 512 * 1024 * 1024) throws -> Data {
        guard entry.uncompressedSize <= maxBytes else {
            throw ZipError.ioError("条目过大，拒绝整块读入内存：\(entry.name)（\(entry.uncompressedSize) 字节）")
        }
        var output = Data()
        output.reserveCapacity(Int(entry.uncompressedSize))
        try streamDecompressed(entry: entry, chunkSize: ZipConstants.defaultChunkSize) { chunk in
            output.append(chunk)
        }
        return output
    }

    public func readData(named name: String) throws -> Data {
        guard let entry = entryMap[name] else {
            throw ZipError.entryNotFound(name)
        }
        return try readData(for: entry)
    }

    /// Reads only the first `prefixBytes` decompressed bytes of an entry without inflating the whole file.
    /// Ideal for probing large files like `global-metadata.dat` in <1ms with minimal memory.
    public func readDecompressedPrefix(for entry: ZipEntry, prefixBytes: Int) throws -> Data {
        guard prefixBytes > 0 else { return Data() }
        let dataOffset = try localDataOffset(for: entry)
        let targetLen = min(prefixBytes, Int(min(entry.uncompressedSize, UInt64(Int.max))))
        if targetLen == 0 { return Data() }

        switch entry.compressionMethod {
        case ZipConstants.methodStored:
            return try Self.preadExact(fd: fd, offset: dataOffset, length: targetLen)

        case ZipConstants.methodDeflated:
            var stream = z_stream()
            let initStatus = inflateInit2_(
                &stream,
                -MAX_WBITS,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
            guard initStatus == Z_OK else {
                throw ZipError.decompressionFailed(entry: entry.name, code: initStatus)
            }
            defer { inflateEnd(&stream) }

            var result = Data()
            result.reserveCapacity(targetLen)
            var outBuffer = [UInt8](repeating: 0, count: min(64 * 1024, max(4096, targetLen)))
            var remaining = entry.compressedSize
            var cursor = dataOffset

            while remaining > 0 && result.count < targetLen {
                try Task.checkCancellation()
                let toRead = Int(min(UInt64(64 * 1024), remaining))
                let compressed = try Self.preadExact(fd: fd, offset: cursor, length: toRead)
                cursor += UInt64(toRead)
                remaining -= UInt64(toRead)

                var done = false
                try compressed.withUnsafeBytes { inRaw in
                    guard let inBase = inRaw.baseAddress?.assumingMemoryBound(to: Bytef.self) else { return }
                    stream.next_in = UnsafeMutablePointer(mutating: inBase)
                    stream.avail_in = uInt(inRaw.count)

                    while stream.avail_in > 0 && result.count < targetLen && !done {
                        var produced = 0
                        let status: Int32 = outBuffer.withUnsafeMutableBufferPointer { outBuf in
                            stream.next_out = outBuf.baseAddress
                            stream.avail_out = uInt(outBuf.count)
                            let res = inflate(&stream, Z_NO_FLUSH)
                            produced = outBuf.count - Int(stream.avail_out)
                            return res
                        }
                        if produced > 0 {
                            let need = min(produced, targetLen - result.count)
                            result.append(outBuffer, count: need)
                        }
                        if status == Z_STREAM_END {
                            done = true
                        } else if status != Z_OK && status != Z_BUF_ERROR {
                            throw ZipError.decompressionFailed(entry: entry.name, code: status)
                        }
                    }
                }
                if done { break }
            }
            return result

        default:
            throw ZipError.unsupportedCompressionMethod(entry.compressionMethod, entry: entry.name)
        }
    }

    /// Resolves the exact byte offset where the entry's compressed payload begins.
    public func localDataOffset(for entry: ZipEntry) throws -> UInt64 {
        guard fileSize >= 30, entry.localHeaderOffset <= fileSize - 30 else {
            throw ZipError.truncatedArchive("条目 \(entry.name) 的 Local File Header 偏移越界")
        }
        let header = try Self.preadExact(fd: fd, offset: entry.localHeaderOffset, length: 30)
        let sig = try header.readUInt32LE(at: 0)
        guard sig == ZipConstants.localFileHeaderSignature else {
            throw ZipError.invalidSignature("条目 \(entry.name) 的 Local File Header 签名错误")
        }
        let nameLen = UInt64(try header.readUInt16LE(at: 26))
        let extraLen = UInt64(try header.readUInt16LE(at: 28))
        let headerTotal = 30 &+ nameLen &+ extraLen // max 30 + 65535 + 65535 = 131100
        guard fileSize >= headerTotal, entry.localHeaderOffset <= fileSize - headerTotal else {
            throw ZipError.truncatedArchive("条目 \(entry.name) 的数据偏移超出文件范围")
        }
        let dataOffset = entry.localHeaderOffset + headerTotal
        guard entry.compressedSize <= fileSize - dataOffset else {
            throw ZipError.truncatedArchive("条目 \(entry.name) 的数据区间超出文件范围")
        }
        return dataOffset
    }

    /// Streams raw compressed bytes of an entry in chunks without decompressing.
    public func streamRawCompressed(
        entry: ZipEntry,
        chunkSize: Int = ZipConstants.defaultChunkSize,
        onChunk: (Data) throws -> Void
    ) throws {
        let dataOffset = try localDataOffset(for: entry)
        var remaining = entry.compressedSize
        var cursor = dataOffset
        let effectiveChunk = max(64 * 1024, chunkSize)

        while remaining > 0 {
            try Task.checkCancellation()
            let toRead = Int(min(UInt64(effectiveChunk), remaining))
            let chunk = try Self.preadExact(fd: fd, offset: cursor, length: toRead)
            try onChunk(chunk)
            cursor += UInt64(toRead)
            remaining -= UInt64(toRead)
        }
    }

    /// Streams decompressed bytes of an entry in chunks, verifying CRC32 and exact uncompressed length.
    public func streamDecompressed(
        entry: ZipEntry,
        chunkSize: Int = ZipConstants.defaultChunkSize,
        onChunk: (Data) throws -> Void
    ) throws {
        let dataOffset = try localDataOffset(for: entry)
        let effectiveChunk = max(64 * 1024, chunkSize)
        var runningCRC: uLong = zlib.crc32(0, nil, 0)
        var totalOut: UInt64 = 0

        switch entry.compressionMethod {
        case ZipConstants.methodStored:
            guard entry.compressedSize == entry.uncompressedSize else {
                throw ZipError.sizeMismatch(
                    entry: entry.name,
                    expected: entry.uncompressedSize,
                    actual: entry.compressedSize
                )
            }
            var remaining = entry.compressedSize
            var cursor = dataOffset
            while remaining > 0 {
                try Task.checkCancellation()
                let toRead = Int(min(UInt64(effectiveChunk), remaining))
                let chunk = try Self.preadExact(fd: fd, offset: cursor, length: toRead)
                chunk.withUnsafeBytes { raw in
                    if let base = raw.baseAddress?.assumingMemoryBound(to: Bytef.self), raw.count > 0 {
                        runningCRC = zlib.crc32(runningCRC, base, uInt(raw.count))
                    }
                }
                totalOut += UInt64(chunk.count)
                try onChunk(chunk)
                cursor += UInt64(toRead)
                remaining -= UInt64(toRead)
            }

        case ZipConstants.methodDeflated:
            var stream = z_stream()
            let initStatus = inflateInit2_(
                &stream,
                -MAX_WBITS,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
            guard initStatus == Z_OK else {
                throw ZipError.decompressionFailed(entry: entry.name, code: initStatus)
            }
            defer { inflateEnd(&stream) }

            var outBuffer = [UInt8](repeating: 0, count: effectiveChunk)
            var remaining = entry.compressedSize
            var cursor = dataOffset
            var streamEnded = false

            if remaining == 0 {
                // Handle empty deflated stream if ever present.
                var emptyByte: UInt8 = 0
                let status: Int32 = withUnsafeMutablePointer(to: &emptyByte) { ptr in
                    stream.next_in = ptr
                    stream.avail_in = 0
                    return outBuffer.withUnsafeMutableBufferPointer { outBuf in
                        stream.next_out = outBuf.baseAddress
                        stream.avail_out = uInt(outBuf.count)
                        return inflate(&stream, Z_FINISH)
                    }
                }
                if status == Z_STREAM_END {
                    streamEnded = true
                }
            }

            while remaining > 0 && !streamEnded {
                try Task.checkCancellation()
                let toRead = Int(min(UInt64(effectiveChunk), remaining))
                let compressedChunk = try Self.preadExact(fd: fd, offset: cursor, length: toRead)
                cursor += UInt64(toRead)
                remaining -= UInt64(toRead)

                try compressedChunk.withUnsafeBytes { inRaw in
                    guard let inBase = inRaw.baseAddress?.assumingMemoryBound(to: Bytef.self) else {
                        return
                    }
                    stream.next_in = UnsafeMutablePointer(mutating: inBase)
                    stream.avail_in = uInt(inRaw.count)

                    while stream.avail_in > 0 && !streamEnded {
                        try Task.checkCancellation()
                        var produced = 0
                        let status: Int32 = outBuffer.withUnsafeMutableBufferPointer { outBuf in
                            stream.next_out = outBuf.baseAddress
                            stream.avail_out = uInt(outBuf.count)
                            let res = inflate(&stream, Z_NO_FLUSH)
                            produced = outBuf.count - Int(stream.avail_out)
                            return res
                        }

                        if produced > 0 {
                            let producedU64 = UInt64(produced)
                            guard producedU64 <= entry.uncompressedSize - totalOut else {
                                throw ZipError.sizeMismatch(
                                    entry: entry.name,
                                    expected: entry.uncompressedSize,
                                    actual: totalOut &+ producedU64
                                )
                            }
                            outBuffer.withUnsafeBytes { raw in
                                if let base = raw.baseAddress?.assumingMemoryBound(to: Bytef.self) {
                                    runningCRC = zlib.crc32(runningCRC, base, uInt(produced))
                                }
                            }
                            totalOut += producedU64
                            try onChunk(Data(bytes: outBuffer, count: produced))
                        }

                        if status == Z_STREAM_END {
                            streamEnded = true
                            break
                        } else if status != Z_OK && status != Z_BUF_ERROR {
                            throw ZipError.decompressionFailed(entry: entry.name, code: status)
                        }
                    }
                }
            }

            // Drain any remaining buffered output in zlib when input ended right before Z_STREAM_END.
            while !streamEnded {
                try Task.checkCancellation()
                var produced = 0
                let status: Int32 = outBuffer.withUnsafeMutableBufferPointer { outBuf in
                    stream.next_in = nil
                    stream.avail_in = 0
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = uInt(outBuf.count)
                    let res = inflate(&stream, Z_FINISH)
                    produced = outBuf.count - Int(stream.avail_out)
                    return res
                }
                if produced > 0 {
                    let producedU64 = UInt64(produced)
                    guard producedU64 <= entry.uncompressedSize - totalOut else {
                        throw ZipError.sizeMismatch(
                            entry: entry.name,
                            expected: entry.uncompressedSize,
                            actual: totalOut &+ producedU64
                        )
                    }
                    outBuffer.withUnsafeBytes { raw in
                        if let base = raw.baseAddress?.assumingMemoryBound(to: Bytef.self) {
                            runningCRC = zlib.crc32(runningCRC, base, uInt(produced))
                        }
                    }
                    totalOut += producedU64
                    try onChunk(Data(bytes: outBuffer, count: produced))
                }
                if status == Z_STREAM_END {
                    streamEnded = true
                } else if status == Z_OK || status == Z_BUF_ERROR {
                    if produced == 0 {
                        throw ZipError.decompressionFailed(entry: entry.name, code: status)
                    }
                } else {
                    throw ZipError.decompressionFailed(entry: entry.name, code: status)
                }
            }

        default:
            throw ZipError.unsupportedCompressionMethod(entry.compressionMethod, entry: entry.name)
        }

        guard totalOut == entry.uncompressedSize else {
            throw ZipError.sizeMismatch(entry: entry.name, expected: entry.uncompressedSize, actual: totalOut)
        }
        let actualCRC = UInt32(truncatingIfNeeded: runningCRC)
        guard actualCRC == entry.crc32 else {
            throw ZipError.crcMismatch(entry: entry.name, expected: entry.crc32, actual: actualCRC)
        }
    }

    /// Streams and decompresses every entry in the archive to verify CRC32 integrity (equivalent to Python `testzip`).
    public func verifyAllEntriesCRC(
        onProgress: ((_ completedEntries: Int, _ totalEntries: Int, _ verifiedBytes: UInt64, _ totalBytes: UInt64) -> Void)? = nil
    ) throws {
        let totalEntries = entries.count
        let totalBytes = entries.reduce(UInt64(0)) { $0 &+ $1.uncompressedSize }
        var verifiedBytes: UInt64 = 0

        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            try streamDecompressed(entry: entry) { chunk in
                verifiedBytes &+= UInt64(chunk.count)
            }
            onProgress?(index + 1, totalEntries, verifiedBytes, totalBytes)
        }
    }

    // MARK: - Central Directory Parsing

    private static func preadExact(fd: Int32, offset: UInt64, length: Int) throws -> Data {
        if length == 0 { return Data() }
        guard length > 0,
              let baseOffset = off_t(exactly: offset),
              let lenOff = off_t(exactly: length),
              baseOffset <= off_t.max - lenOff else {
            throw ZipError.truncatedArchive("读取文件偏移越界（offset=\(offset), length=\(length)）")
        }
        var buffer = Data(count: length)
        var totalRead = 0
        try buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while totalRead < length {
                let n = pread(fd, base.advanced(by: totalRead), length - totalRead, baseOffset + off_t(totalRead))
                if n < 0 {
                    if errno == EINTR { continue }
                    let errStr = String(cString: strerror(errno))
                    throw ZipError.ioError("读取文件偏移 \(offset) 失败：\(errStr)")
                }
                if n == 0 {
                    throw ZipError.truncatedArchive("读取偏移 \(offset) 时提前到达文件末尾")
                }
                totalRead += n
            }
        }
        return buffer
    }

    private static func parseCentralDirectory(fd: Int32, fileSize: UInt64) throws -> [ZipEntry] {
        // Locate End of Central Directory (EOCD) scanning backwards up to 65535 + 22 bytes.
        let maxTail = Int(min(fileSize, UInt64(65535 + 22)))
        let tailOffset = fileSize - UInt64(maxTail)
        let tail = try preadExact(fd: fd, offset: tailOffset, length: maxTail)

        var eocdRelativeOffset: Int?
        var pos = maxTail - 22
        while pos >= 0 {
            let sig = try tail.readUInt32LE(at: pos)
            if sig == ZipConstants.eocdSignature {
                let commentLen = Int(try tail.readUInt16LE(at: pos + 20))
                if pos + 22 + commentLen == maxTail {
                    eocdRelativeOffset = pos
                    break
                }
            }
            pos -= 1
        }

        guard let eocdRel = eocdRelativeOffset else {
            throw ZipError.invalidSignature("未找到 ZIP 结束目录记录（EOCD）")
        }

        let eocdOffset = tailOffset + UInt64(eocdRel)
        let eocdTotalEntries16 = try tail.readUInt16LE(at: eocdRel + 10)
        let eocdCDSize32 = try tail.readUInt32LE(at: eocdRel + 12)
        let eocdCDOffset32 = try tail.readUInt32LE(at: eocdRel + 16)

        var totalEntries = UInt64(eocdTotalEntries16)
        var cdSize = UInt64(eocdCDSize32)
        var cdOffset = UInt64(eocdCDOffset32)

        // Check for ZIP64 EOCD Locator immediately preceding EOCD.
        if eocdOffset >= 20 {
            let locatorData = try preadExact(fd: fd, offset: eocdOffset - 20, length: 20)
            let locatorSig = try locatorData.readUInt32LE(at: 0)
            if locatorSig == ZipConstants.zip64EOCDLocatorSignature {
                let zip64EOCDOffset = try locatorData.readUInt64LE(at: 8)
                guard fileSize >= 56, zip64EOCDOffset <= fileSize - 56 else {
                    throw ZipError.truncatedArchive("ZIP64 EOCD 偏移越界")
                }
                let zip64EOCD = try preadExact(fd: fd, offset: zip64EOCDOffset, length: 56)
                let z64Sig = try zip64EOCD.readUInt32LE(at: 0)
                guard z64Sig == ZipConstants.zip64EOCDSignature else {
                    throw ZipError.invalidSignature("ZIP64 EOCD 签名无效")
                }
                let z64TotalEntries = try zip64EOCD.readUInt64LE(at: 32)
                let z64CDSize = try zip64EOCD.readUInt64LE(at: 40)
                let z64CDOffset = try zip64EOCD.readUInt64LE(at: 48)

                if eocdTotalEntries16 == ZipConstants.maxUInt16 { totalEntries = z64TotalEntries }
                if eocdCDSize32 == ZipConstants.maxUInt32 { cdSize = z64CDSize }
                if eocdCDOffset32 == ZipConstants.maxUInt32 { cdOffset = z64CDOffset }
            }
        }

        guard cdOffset <= fileSize && cdSize <= fileSize - cdOffset else {
            throw ZipError.truncatedArchive("中央目录区间超出文件大小")
        }
        guard cdSize <= 512 * 1024 * 1024 else {
            throw ZipError.ioError("中央目录异常过大（\(cdSize) 字节）")
        }

        let cdData = try preadExact(fd: fd, offset: cdOffset, length: Int(cdSize))
        var entries: [ZipEntry] = []
        entries.reserveCapacity(Int(min(totalEntries, 1_000_000)))

        var cursor = 0
        while cursor < cdData.count {
            guard cursor + 46 <= cdData.count else {
                throw ZipError.truncatedArchive("中央目录条目头不完整")
            }
            let sig = try cdData.readUInt32LE(at: cursor)
            guard sig == ZipConstants.centralDirectorySignature else {
                throw ZipError.invalidSignature("中央目录条目签名无效（offset=\(cursor)）")
            }

            let versionMadeBy = try cdData.readUInt16LE(at: cursor + 4)
            let flags = try cdData.readUInt16LE(at: cursor + 8)
            let method = try cdData.readUInt16LE(at: cursor + 10)
            let dosTime = try cdData.readUInt16LE(at: cursor + 12)
            let dosDate = try cdData.readUInt16LE(at: cursor + 14)
            let crc32 = try cdData.readUInt32LE(at: cursor + 16)
            let compressedSize32 = try cdData.readUInt32LE(at: cursor + 20)
            let uncompressedSize32 = try cdData.readUInt32LE(at: cursor + 24)
            let nameLen = Int(try cdData.readUInt16LE(at: cursor + 28))
            let extraLen = Int(try cdData.readUInt16LE(at: cursor + 30))
            let commentLen = Int(try cdData.readUInt16LE(at: cursor + 32))
            let externalAttrs = try cdData.readUInt32LE(at: cursor + 38)
            let localHeaderOffset32 = try cdData.readUInt32LE(at: cursor + 42)

            let recordEnd = cursor + 46 + nameLen + extraLen + commentLen
            guard recordEnd <= cdData.count else {
                throw ZipError.truncatedArchive("中央目录变长字段越界")
            }

            let nameStart = cursor + 46
            let nameData = cdData.subdata(in: nameStart..<(nameStart + nameLen))
            let name: String
            if let utf8 = String(data: nameData, encoding: .utf8) {
                name = utf8
            } else {
                name = String(decoding: nameData, as: UTF8.self)
            }

            var compressedSize = UInt64(compressedSize32)
            var uncompressedSize = UInt64(uncompressedSize32)
            var localHeaderOffset = UInt64(localHeaderOffset32)

            let needsZip64Uncompressed = uncompressedSize32 == ZipConstants.maxUInt32
            let needsZip64Compressed = compressedSize32 == ZipConstants.maxUInt32
            let needsZip64Offset = localHeaderOffset32 == ZipConstants.maxUInt32

            if needsZip64Uncompressed || needsZip64Compressed || needsZip64Offset {
                let extraStart = nameStart + nameLen
                let extraData = cdData.subdata(in: extraStart..<(extraStart + extraLen))
                let parsed64 = try parseZip64ExtraField(
                    extraData,
                    needsUncompressed: needsZip64Uncompressed,
                    needsCompressed: needsZip64Compressed,
                    needsOffset: needsZip64Offset
                )
                if let u = parsed64.uncompressed { uncompressedSize = u }
                if let c = parsed64.compressed { compressedSize = c }
                if let o = parsed64.offset { localHeaderOffset = o }
            }

            entries.append(
                ZipEntry(
                    name: name,
                    compressionMethod: method,
                    crc32: crc32,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localHeaderOffset,
                    versionMadeBy: versionMadeBy,
                    generalPurposeBitFlag: flags,
                    dosTime: dosTime,
                    dosDate: dosDate,
                    externalFileAttributes: externalAttrs
                )
            )
            cursor = recordEnd
        }

        guard UInt64(entries.count) == totalEntries else {
            throw ZipError.truncatedArchive("中央目录条目数与目录尾记录不一致（声明 \(totalEntries)，实际 \(entries.count)）")
        }

        return entries
    }

    private static func parseZip64ExtraField(
        _ extra: Data,
        needsUncompressed: Bool,
        needsCompressed: Bool,
        needsOffset: Bool
    ) throws -> (uncompressed: UInt64?, compressed: UInt64?, offset: UInt64?) {
        var pos = 0
        while pos + 4 <= extra.count {
            let headerID = try extra.readUInt16LE(at: pos)
            let dataSize = Int(try extra.readUInt16LE(at: pos + 2))
            pos += 4
            guard pos + dataSize <= extra.count else {
                throw ZipError.invalidZip64Field("Extra field 长度越界")
            }
            if headerID == ZipConstants.zip64ExtraFieldHeaderID {
                var fieldCursor = pos
                let fieldEnd = pos + dataSize
                var uncompressed: UInt64?
                var compressed: UInt64?
                var offset: UInt64?

                // Strict APPNOTE 4.5.3 order: uncompressed -> compressed -> local header offset -> disk number.
                if needsUncompressed {
                    guard fieldCursor + 8 <= fieldEnd else {
                        throw ZipError.invalidZip64Field("缺少 ZIP64 原始大小字段")
                    }
                    uncompressed = try extra.readUInt64LE(at: fieldCursor)
                    fieldCursor += 8
                }
                if needsCompressed {
                    guard fieldCursor + 8 <= fieldEnd else {
                        throw ZipError.invalidZip64Field("缺少 ZIP64 压缩大小字段")
                    }
                    compressed = try extra.readUInt64LE(at: fieldCursor)
                    fieldCursor += 8
                }
                if needsOffset {
                    guard fieldCursor + 8 <= fieldEnd else {
                        throw ZipError.invalidZip64Field("缺少 ZIP64 偏移字段")
                    }
                    offset = try extra.readUInt64LE(at: fieldCursor)
                    fieldCursor += 8
                }
                return (uncompressed, compressed, offset)
            }
            pos += dataSize
        }
        throw ZipError.invalidZip64Field("未找到 ZIP64 扩展字段（0x0001）")
    }
}
