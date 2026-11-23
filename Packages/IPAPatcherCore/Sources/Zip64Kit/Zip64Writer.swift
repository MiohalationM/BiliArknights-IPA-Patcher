import Darwin
import Foundation
import zlib

/// Single-pass streaming ZIP/ZIP64 writer backed by POSIX file I/O and system `zlib`.
/// Writes local headers + payloads sequentially once, then writes the Central Directory & EOCD once at `finish()`.
public final class Zip64Writer {
    public let url: URL
    private let forceZip64: Bool
    private var fd: Int32
    private var currentOffset: UInt64 = 0
    private var records: [CentralDirectoryRecord] = []
    private var writtenNames: Set<String> = []
    private var isFinalized: Bool = false
    private var isClosed: Bool = false

    private struct CentralDirectoryRecord {
        let nameData: Data
        let versionMadeBy: UInt16
        let versionNeeded: UInt16
        let flags: UInt16
        let compressionMethod: UInt16
        let dosTime: UInt16
        let dosDate: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let externalAttributes: UInt32
        let localHeaderOffset: UInt64
    }

    public init(url: URL, forceZip64: Bool = false) throws {
        self.url = url
        self.forceZip64 = forceZip64
        let openedFD = open(url.path, O_CREAT | O_EXCL | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard openedFD >= 0 else {
            let errStr = String(cString: strerror(errno))
            throw ZipError.ioError("无法创建临时输出文件 \(url.lastPathComponent)：\(errStr)")
        }
        self.fd = openedFD
    }

    deinit {
        if !isClosed {
            close(fd)
            isClosed = true
        }
    }

    /// Writes a directory entry (stored, 0 bytes).
    @discardableResult
    public func writeDirectoryEntry(
        name: String,
        versionMadeBy: UInt16 = ZipConstants.unixCreatorSystem | 45,
        externalAttributes: UInt32 = (0o040755 << 16),
        dosTime: UInt16? = nil,
        dosDate: UInt16? = nil
    ) throws -> WrittenZipEntry {
        try ensureWritable(name: name)
        let now = DosDateTime.encode()
        let time = dosTime ?? now.dosTime
        let date = dosDate ?? now.dosDate
        let nameData = Data(name.utf8)
        let flags: UInt16 = ZipConstants.flagUTF8Encoding
        let localOffset = currentOffset
        let useZip64Sizes = forceZip64

        let header = buildLocalFileHeader(
            nameData: nameData,
            versionNeeded: useZip64Sizes ? 45 : 20,
            flags: flags,
            method: ZipConstants.methodStored,
            dosTime: time,
            dosDate: date,
            crc32: 0,
            compressedSize: 0,
            uncompressedSize: 0,
            includeZip64Extra: useZip64Sizes
        )
        try writeAll(header)

        records.append(
            CentralDirectoryRecord(
                nameData: nameData,
                versionMadeBy: versionMadeBy,
                versionNeeded: useZip64Sizes ? 45 : 20,
                flags: flags,
                compressionMethod: ZipConstants.methodStored,
                dosTime: time,
                dosDate: date,
                crc32: 0,
                compressedSize: 0,
                uncompressedSize: 0,
                externalAttributes: externalAttributes,
                localHeaderOffset: localOffset
            )
        )
        writtenNames.insert(name)
        return WrittenZipEntry(name: name, crc32: 0, compressedSize: 0, uncompressedSize: 0)
    }

    /// Compresses and writes an entry with streaming Deflate (default level 1 / `Z_BEST_SPEED`), updating the LFH in place.
    @discardableResult
    public func writeDeflatedEntry(
        name: String,
        data: Data,
        versionMadeBy: UInt16 = ZipConstants.unixCreatorSystem | 45,
        externalAttributes: UInt32,
        dosTime: UInt16? = nil,
        dosDate: UInt16? = nil,
        compressionLevel: Int32 = Z_BEST_SPEED,
        chunkSize: Int = ZipConstants.defaultChunkSize
    ) throws -> WrittenZipEntry {
        try ensureWritable(name: name)
        try Task.checkCancellation()

        let now = DosDateTime.encode()
        let time = dosTime ?? now.dosTime
        let date = dosDate ?? now.dosDate
        let nameData = Data(name.utf8)
        let flags: UInt16 = ZipConstants.flagUTF8Encoding
        let localOffset = currentOffset
        let uncompressedSize = UInt64(data.count)
        let reserveZip64 = forceZip64 || uncompressedSize >= 0xF000_0000

        let placeholderHeader = buildLocalFileHeader(
            nameData: nameData,
            versionNeeded: reserveZip64 ? 45 : 20,
            flags: flags,
            method: ZipConstants.methodDeflated,
            dosTime: time,
            dosDate: date,
            crc32: 0,
            compressedSize: 0,
            uncompressedSize: 0,
            includeZip64Extra: reserveZip64
        )
        try writeAll(placeholderHeader)

        // Stream-deflate data directly to disk in chunks.
        var stream = z_stream()
        let initStatus = deflateInit2_(
            &stream,
            compressionLevel,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw ZipError.compressionFailed(entry: name, code: initStatus)
        }
        defer { deflateEnd(&stream) }

        let effectiveChunk = max(64 * 1024, chunkSize)
        var outBuffer = [UInt8](repeating: 0, count: effectiveChunk)
        var runningCRC: uLong = zlib.crc32(0, nil, 0)
        var compressedTotal: UInt64 = 0

        try data.withUnsafeBytes { raw in
            let totalLen = raw.count
            let basePtr = raw.baseAddress?.assumingMemoryBound(to: Bytef.self)
            var inputCursor = 0

            while true {
                try Task.checkCancellation()
                let isLastChunk = inputCursor >= totalLen
                let stepLen = isLastChunk ? 0 : min(effectiveChunk, totalLen - inputCursor)

                if stepLen > 0, let basePtr {
                    let chunkPtr = basePtr.advanced(by: inputCursor)
                    runningCRC = zlib.crc32(runningCRC, chunkPtr, uInt(stepLen))
                    stream.next_in = UnsafeMutablePointer(mutating: chunkPtr)
                    stream.avail_in = uInt(stepLen)
                    inputCursor += stepLen
                } else {
                    stream.next_in = nil
                    stream.avail_in = 0
                }

                let flushMode = (inputCursor >= totalLen) ? Z_FINISH : Z_NO_FLUSH

                while true {
                    try Task.checkCancellation()
                    var produced = 0
                    let status: Int32 = outBuffer.withUnsafeMutableBufferPointer { outBuf in
                        stream.next_out = outBuf.baseAddress
                        stream.avail_out = uInt(outBuf.count)
                        let res = deflate(&stream, flushMode)
                        produced = outBuf.count - Int(stream.avail_out)
                        return res
                    }

                    if produced > 0 {
                        try writeBytes(outBuffer, count: produced)
                        compressedTotal += UInt64(produced)
                    }

                    if status == Z_STREAM_END {
                        return
                    } else if status == Z_OK || status == Z_BUF_ERROR {
                        if flushMode == Z_NO_FLUSH && stream.avail_in == 0 && stream.avail_out > 0 {
                            break
                        }
                        if produced == 0 && stream.avail_in == 0 && flushMode == Z_FINISH {
                            throw ZipError.compressionFailed(entry: name, code: status)
                        }
                    } else {
                        throw ZipError.compressionFailed(entry: name, code: status)
                    }
                }
            }
        }

        let finalCRC = UInt32(truncatingIfNeeded: runningCRC)
        let patchedHeader = buildLocalFileHeader(
            nameData: nameData,
            versionNeeded: reserveZip64 ? 45 : 20,
            flags: flags,
            method: ZipConstants.methodDeflated,
            dosTime: time,
            dosDate: date,
            crc32: finalCRC,
            compressedSize: compressedTotal,
            uncompressedSize: uncompressedSize,
            includeZip64Extra: reserveZip64
        )
        try pwriteAll(patchedHeader, at: localOffset)

        let versionNeeded: UInt16 = (
            reserveZip64
                || compressedTotal >= UInt64(ZipConstants.maxUInt32)
                || uncompressedSize >= UInt64(ZipConstants.maxUInt32)
                || localOffset >= UInt64(ZipConstants.maxUInt32)
        ) ? 45 : 20

        records.append(
            CentralDirectoryRecord(
                nameData: nameData,
                versionMadeBy: versionMadeBy,
                versionNeeded: versionNeeded,
                flags: flags,
                compressionMethod: ZipConstants.methodDeflated,
                dosTime: time,
                dosDate: date,
                crc32: finalCRC,
                compressedSize: compressedTotal,
                uncompressedSize: uncompressedSize,
                externalAttributes: externalAttributes,
                localHeaderOffset: localOffset
            )
        )
        writtenNames.insert(name)
        return WrittenZipEntry(
            name: name,
            crc32: finalCRC,
            compressedSize: compressedTotal,
            uncompressedSize: uncompressedSize
        )
    }

    /// Copies an unchanged entry's raw compressed stream in chunks directly from `reader` into this archive.
    @discardableResult
    public func copyRawEntry(
        from reader: Zip64Reader,
        entry: ZipEntry,
        chunkSize: Int = ZipConstants.defaultChunkSize,
        onBytesCopied: ((UInt64) -> Void)? = nil
    ) throws -> WrittenZipEntry {
        try ensureWritable(name: entry.name)
        guard entry.compressionMethod == ZipConstants.methodStored || entry.compressionMethod == ZipConstants.methodDeflated else {
            throw ZipError.unsupportedCompressionMethod(entry.compressionMethod, entry: entry.name)
        }

        let nameData = Data(entry.name.utf8)
        // Clear bit 3 (data descriptor) because exact CRC & sizes are written in LFH; ensure UTF-8 flag.
        let cleanFlags = (entry.generalPurposeBitFlag & ~ZipConstants.flagDataDescriptor) | ZipConstants.flagUTF8Encoding
        let localOffset = currentOffset
        let needsZip64LFH = forceZip64
            || entry.compressedSize >= UInt64(ZipConstants.maxUInt32)
            || entry.uncompressedSize >= UInt64(ZipConstants.maxUInt32)
        let needsZip64CD = needsZip64LFH || localOffset >= UInt64(ZipConstants.maxUInt32)

        let header = buildLocalFileHeader(
            nameData: nameData,
            versionNeeded: needsZip64LFH ? 45 : 20,
            flags: cleanFlags,
            method: entry.compressionMethod,
            dosTime: entry.dosTime,
            dosDate: entry.dosDate,
            crc32: entry.crc32,
            compressedSize: entry.compressedSize,
            uncompressedSize: entry.uncompressedSize,
            includeZip64Extra: needsZip64LFH
        )
        try writeAll(header)

        var copied: UInt64 = 0
        try reader.streamRawCompressed(entry: entry, chunkSize: chunkSize) { chunk in
            try self.writeAll(chunk)
            copied += UInt64(chunk.count)
            onBytesCopied?(UInt64(chunk.count))
        }
        guard copied == entry.compressedSize else {
            throw ZipError.sizeMismatch(entry: entry.name, expected: entry.compressedSize, actual: copied)
        }

        records.append(
            CentralDirectoryRecord(
                nameData: nameData,
                versionMadeBy: entry.versionMadeBy,
                versionNeeded: needsZip64CD ? 45 : 20,
                flags: cleanFlags,
                compressionMethod: entry.compressionMethod,
                dosTime: entry.dosTime,
                dosDate: entry.dosDate,
                crc32: entry.crc32,
                compressedSize: entry.compressedSize,
                uncompressedSize: entry.uncompressedSize,
                externalAttributes: entry.externalFileAttributes,
                localHeaderOffset: localOffset
            )
        )
        writtenNames.insert(entry.name)
        return WrittenZipEntry(
            name: entry.name,
            crc32: entry.crc32,
            compressedSize: entry.compressedSize,
            uncompressedSize: entry.uncompressedSize
        )
    }

    /// Writes the Central Directory, optional ZIP64 EOCD & Locator, and standard EOCD, then closes the file.
    public func finish() throws {
        guard !isFinalized else { throw ZipError.alreadyFinalized }
        try Task.checkCancellation()

        let cdOffset = currentOffset
        var cdBuffer = Data()
        cdBuffer.reserveCapacity(records.count * 96)

        for record in records {
            let needsZip64Uncompressed = forceZip64 || record.uncompressedSize >= UInt64(ZipConstants.maxUInt32)
            let needsZip64Compressed = forceZip64 || record.compressedSize >= UInt64(ZipConstants.maxUInt32)
            let needsZip64Offset = forceZip64 || record.localHeaderOffset >= UInt64(ZipConstants.maxUInt32)

            var zip64Extra = Data()
            if needsZip64Uncompressed || needsZip64Compressed || needsZip64Offset {
                var payload = Data()
                if needsZip64Uncompressed { payload.appendUInt64LE(record.uncompressedSize) }
                if needsZip64Compressed { payload.appendUInt64LE(record.compressedSize) }
                if needsZip64Offset { payload.appendUInt64LE(record.localHeaderOffset) }

                zip64Extra.appendUInt16LE(ZipConstants.zip64ExtraFieldHeaderID)
                zip64Extra.appendUInt16LE(UInt16(payload.count))
                zip64Extra.append(payload)
            }

            cdBuffer.appendUInt32LE(ZipConstants.centralDirectorySignature)
            cdBuffer.appendUInt16LE(record.versionMadeBy)
            cdBuffer.appendUInt16LE(zip64Extra.isEmpty ? record.versionNeeded : 45)
            cdBuffer.appendUInt16LE(record.flags)
            cdBuffer.appendUInt16LE(record.compressionMethod)
            cdBuffer.appendUInt16LE(record.dosTime)
            cdBuffer.appendUInt16LE(record.dosDate)
            cdBuffer.appendUInt32LE(record.crc32)
            cdBuffer.appendUInt32LE(needsZip64Compressed ? ZipConstants.maxUInt32 : UInt32(record.compressedSize))
            cdBuffer.appendUInt32LE(needsZip64Uncompressed ? ZipConstants.maxUInt32 : UInt32(record.uncompressedSize))
            cdBuffer.appendUInt16LE(UInt16(record.nameData.count))
            cdBuffer.appendUInt16LE(UInt16(zip64Extra.count))
            cdBuffer.appendUInt16LE(0) // file comment length
            cdBuffer.appendUInt16LE(0) // disk number start
            cdBuffer.appendUInt16LE(0) // internal file attributes
            cdBuffer.appendUInt32LE(record.externalAttributes)
            cdBuffer.appendUInt32LE(needsZip64Offset ? ZipConstants.maxUInt32 : UInt32(record.localHeaderOffset))
            cdBuffer.append(record.nameData)
            cdBuffer.append(zip64Extra)
        }

        try writeAll(cdBuffer)
        let cdSize = UInt64(cdBuffer.count)
        let entryCount = UInt64(records.count)

        let needsZip64EOCD = forceZip64
            || entryCount >= UInt64(ZipConstants.maxUInt16)
            || cdSize >= UInt64(ZipConstants.maxUInt32)
            || cdOffset >= UInt64(ZipConstants.maxUInt32)

        if needsZip64EOCD {
            let zip64EOCDOffset = currentOffset
            var z64EOCD = Data()
            z64EOCD.appendUInt32LE(ZipConstants.zip64EOCDSignature)
            z64EOCD.appendUInt64LE(44) // size of remaining ZIP64 EOCD record
            z64EOCD.appendUInt16LE(ZipConstants.unixCreatorSystem | 45)
            z64EOCD.appendUInt16LE(45)
            z64EOCD.appendUInt32LE(0) // disk number
            z64EOCD.appendUInt32LE(0) // disk with start of CD
            z64EOCD.appendUInt64LE(entryCount)
            z64EOCD.appendUInt64LE(entryCount)
            z64EOCD.appendUInt64LE(cdSize)
            z64EOCD.appendUInt64LE(cdOffset)
            try writeAll(z64EOCD)

            var z64Locator = Data()
            z64Locator.appendUInt32LE(ZipConstants.zip64EOCDLocatorSignature)
            z64Locator.appendUInt32LE(0) // disk with start of ZIP64 EOCD
            z64Locator.appendUInt64LE(zip64EOCDOffset)
            z64Locator.appendUInt32LE(1) // total number of disks
            try writeAll(z64Locator)
        }

        var eocd = Data()
        eocd.appendUInt32LE(ZipConstants.eocdSignature)
        eocd.appendUInt16LE(0) // disk number
        eocd.appendUInt16LE(0) // disk with start of CD
        eocd.appendUInt16LE(needsZip64EOCD ? ZipConstants.maxUInt16 : UInt16(entryCount))
        eocd.appendUInt16LE(needsZip64EOCD ? ZipConstants.maxUInt16 : UInt16(entryCount))
        eocd.appendUInt32LE(needsZip64EOCD ? ZipConstants.maxUInt32 : UInt32(cdSize))
        eocd.appendUInt32LE(needsZip64EOCD ? ZipConstants.maxUInt32 : UInt32(cdOffset))
        eocd.appendUInt16LE(0) // comment length
        try writeAll(eocd)

        isFinalized = true
        if !isClosed {
            if close(fd) != 0 {
                isClosed = true
                let errStr = String(cString: strerror(errno))
                throw ZipError.ioError("关闭输出文件失败：\(errStr)")
            }
            isClosed = true
        }
    }

    /// Closes the file descriptor and deletes the unfinished output file.
    public func abortAndRemove() {
        if !isClosed {
            close(fd)
            isClosed = true
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Private Helpers

    private func ensureWritable(name: String) throws {
        guard !isFinalized && !isClosed else { throw ZipError.alreadyFinalized }
        try ZipPathValidator.validateSinglePath(name)
        guard !writtenNames.contains(name) else { throw ZipError.duplicateEntry(name) }
    }

    private func buildLocalFileHeader(
        nameData: Data,
        versionNeeded: UInt16,
        flags: UInt16,
        method: UInt16,
        dosTime: UInt16,
        dosDate: UInt16,
        crc32: UInt32,
        compressedSize: UInt64,
        uncompressedSize: UInt64,
        includeZip64Extra: Bool
    ) -> Data {
        var extra = Data()
        if includeZip64Extra {
            extra.appendUInt16LE(ZipConstants.zip64ExtraFieldHeaderID)
            extra.appendUInt16LE(16)
            extra.appendUInt64LE(uncompressedSize)
            extra.appendUInt64LE(compressedSize)
        }

        var header = Data()
        header.reserveCapacity(30 + nameData.count + extra.count)
        header.appendUInt32LE(ZipConstants.localFileHeaderSignature)
        header.appendUInt16LE(versionNeeded)
        header.appendUInt16LE(flags)
        header.appendUInt16LE(method)
        header.appendUInt16LE(dosTime)
        header.appendUInt16LE(dosDate)
        header.appendUInt32LE(crc32)
        header.appendUInt32LE(includeZip64Extra ? ZipConstants.maxUInt32 : UInt32(compressedSize))
        header.appendUInt32LE(includeZip64Extra ? ZipConstants.maxUInt32 : UInt32(uncompressedSize))
        header.appendUInt16LE(UInt16(nameData.count))
        header.appendUInt16LE(UInt16(extra.count))
        header.append(nameData)
        header.append(extra)
        return header
    }

    private func writeAll(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            try writeRawPointer(base, count: raw.count)
        }
    }

    private func writeBytes(_ bytes: [UInt8], count: Int) throws {
        guard count > 0 else { return }
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            try writeRawPointer(base, count: count)
        }
    }

    private func writeRawPointer(_ base: UnsafeRawPointer, count: Int) throws {
        var written = 0
        while written < count {
            let n = pwrite(fd, base.advanced(by: written), count - written, off_t(currentOffset) + off_t(written))
            if n < 0 {
                if errno == EINTR { continue }
                let errStr = String(cString: strerror(errno))
                throw ZipError.ioError("写入输出文件失败：\(errStr)")
            }
            written += n
        }
        currentOffset += UInt64(count)
    }

    private func pwriteAll(_ data: Data, at offset: UInt64) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = pwrite(fd, base.advanced(by: written), raw.count - written, off_t(offset) + off_t(written))
                if n < 0 {
                    if errno == EINTR { continue }
                    let errStr = String(cString: strerror(errno))
                    throw ZipError.ioError("回写 ZIP 头失败：\(errStr)")
                }
                written += n
            }
        }
    }
}
