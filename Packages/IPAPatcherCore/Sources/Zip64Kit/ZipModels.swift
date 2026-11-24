import Foundation

public enum ZipConstants {
    public static let localFileHeaderSignature: UInt32 = 0x04034b50
    public static let dataDescriptorSignature: UInt32 = 0x08074b50
    public static let centralDirectorySignature: UInt32 = 0x02014b50
    public static let zip64EOCDSignature: UInt32 = 0x06064b50
    public static let zip64EOCDLocatorSignature: UInt32 = 0x07064b50
    public static let eocdSignature: UInt32 = 0x06054b50

    public static let zip64ExtraFieldHeaderID: UInt16 = 0x0001

    public static let methodStored: UInt16 = 0
    public static let methodDeflated: UInt16 = 8

    public static let flagEncrypted: UInt16 = 0x0001
    public static let flagDataDescriptor: UInt16 = 0x0008
    public static let flagUTF8Encoding: UInt16 = 0x0800

    public static let maxUInt16: UInt16 = 0xFFFF
    public static let maxUInt32: UInt32 = 0xFFFFFFFF

    public static let unixCreatorSystem: UInt16 = 3 << 8 // create_system = 3 (Unix)
    public static let defaultChunkSize: Int = 2 * 1024 * 1024
}

public struct ZipEntry: Sendable, Hashable {
    public let name: String
    public let compressionMethod: UInt16
    public let crc32: UInt32
    public let compressedSize: UInt64
    public let uncompressedSize: UInt64
    public let localHeaderOffset: UInt64
    public let versionMadeBy: UInt16
    public let generalPurposeBitFlag: UInt16
    public let dosTime: UInt16
    public let dosDate: UInt16
    public let externalFileAttributes: UInt32

    public var isDirectory: Bool {
        name.hasSuffix("/")
    }

    public var isEncrypted: Bool {
        (generalPurposeBitFlag & ZipConstants.flagEncrypted) != 0
    }

    public init(
        name: String,
        compressionMethod: UInt16,
        crc32: UInt32,
        compressedSize: UInt64,
        uncompressedSize: UInt64,
        localHeaderOffset: UInt64,
        versionMadeBy: UInt16,
        generalPurposeBitFlag: UInt16,
        dosTime: UInt16,
        dosDate: UInt16,
        externalFileAttributes: UInt32
    ) {
        self.name = name
        self.compressionMethod = compressionMethod
        self.crc32 = crc32
        self.compressedSize = compressedSize
        self.uncompressedSize = uncompressedSize
        self.localHeaderOffset = localHeaderOffset
        self.versionMadeBy = versionMadeBy
        self.generalPurposeBitFlag = generalPurposeBitFlag
        self.dosTime = dosTime
        self.dosDate = dosDate
        self.externalFileAttributes = externalFileAttributes
    }
}

public struct WrittenZipEntry: Sendable, Hashable {
    public let name: String
    public let crc32: UInt32
    public let compressedSize: UInt64
    public let uncompressedSize: UInt64
}

public enum ZipPathValidator {
    /// Matches Python `safe_zip`: rejects duplicates, absolute paths, `..` components, `\`, `:`, and `\0`.
    public static func validateSinglePath(_ name: String) throws {
        guard !name.isEmpty else {
            throw ZipError.unsafeEntryPath(name)
        }
        if name.hasPrefix("/") || name.contains("\\") || name.contains(":") || name.contains("\0") {
            throw ZipError.unsafeEntryPath(name)
        }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains("..") {
            throw ZipError.unsafeEntryPath(name)
        }
    }

    public static func validate(names: [String]) throws {
        var seen = Set<String>()
        seen.reserveCapacity(names.count)
        for name in names {
            try validateSinglePath(name)
            if !seen.insert(name).inserted {
                throw ZipError.duplicateEntry(name)
            }
        }
    }
}

public enum DosDateTime {
    public static func encode(date: Date = Date()) -> (dosTime: UInt16, dosDate: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, comps.year ?? 1980)) - 1980
        let month = max(1, min(12, comps.month ?? 1))
        let day = max(1, min(31, comps.day ?? 1))
        let hour = max(0, min(23, comps.hour ?? 0))
        let minute = max(0, min(59, comps.minute ?? 0))
        let second = max(0, min(59, comps.second ?? 0)) / 2

        let dosTime = UInt16((hour << 11) | (minute << 5) | second)
        let dosDate = UInt16((year << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }
}

// MARK: - Unaligned-safe Little-Endian Helpers

extension Data {
    func readUInt16LE(at offset: Int) throws -> UInt16 {
        guard offset >= 0 && offset + 2 <= count else {
            throw ZipError.truncatedArchive("读取 UInt16 越界（offset=\(offset), len=\(count)）")
        }
        let i = startIndex + offset
        return UInt16(self[i]) | (UInt16(self[i + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) throws -> UInt32 {
        guard offset >= 0 && offset + 4 <= count else {
            throw ZipError.truncatedArchive("读取 UInt32 越界（offset=\(offset), len=\(count)）")
        }
        let i = startIndex + offset
        return UInt32(self[i])
            | (UInt32(self[i + 1]) << 8)
            | (UInt32(self[i + 2]) << 16)
            | (UInt32(self[i + 3]) << 24)
    }

    func readUInt64LE(at offset: Int) throws -> UInt64 {
        guard offset >= 0 && offset + 8 <= count else {
            throw ZipError.truncatedArchive("读取 UInt64 越界（offset=\(offset), len=\(count)）")
        }
        let low = UInt64(try readUInt32LE(at: offset))
        let high = UInt64(try readUInt32LE(at: offset + 4))
        return low | (high << 32)
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        appendUInt32LE(UInt32(value & 0xFFFFFFFF))
        appendUInt32LE(UInt32((value >> 32) & 0xFFFFFFFF))
    }
}
