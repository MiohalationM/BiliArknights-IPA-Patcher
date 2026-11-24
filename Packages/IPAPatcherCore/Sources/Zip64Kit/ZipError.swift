import Foundation

public enum ZipError: Error, LocalizedError, Sendable, Equatable {
    case ioError(String)
    case invalidSignature(String)
    case truncatedArchive(String)
    case unsupportedCompressionMethod(UInt16, entry: String)
    case encryptedArchive(entry: String)
    case duplicateEntry(String)
    case unsafeEntryPath(String)
    case entryNotFound(String)
    case decompressionFailed(entry: String, code: Int32)
    case compressionFailed(entry: String, code: Int32)
    case crcMismatch(entry: String, expected: UInt32, actual: UInt32)
    case sizeMismatch(entry: String, expected: UInt64, actual: UInt64)
    case invalidZip64Field(String)
    case alreadyFinalized

    public var errorDescription: String? {
        switch self {
        case .ioError(let message):
            return "ZIP 文件读写失败：\(message)"
        case .invalidSignature(let message):
            return "无效的 ZIP 格式签名：\(message)"
        case .truncatedArchive(let message):
            return "ZIP 文件不完整或已截断：\(message)"
        case .unsupportedCompressionMethod(let method, let entry):
            return "不支持的 ZIP 压缩方式（\(method)）：\(entry)"
        case .encryptedArchive(let entry):
            return "不支持加密的 ZIP 条目：\(entry)"
        case .duplicateEntry(let name):
            return "ZIP 包含重复条目：\(name)"
        case .unsafeEntryPath(let name):
            return "ZIP 包含不安全路径条目：\(name)"
        case .entryNotFound(let name):
            return "ZIP 中未找到条目：\(name)"
        case .decompressionFailed(let entry, let code):
            return "解压条目失败（zlib 错误 \(code)）：\(entry)"
        case .compressionFailed(let entry, let code):
            return "压缩条目失败（zlib 错误 \(code)）：\(entry)"
        case .crcMismatch(let entry, let expected, let actual):
            return String(
                format: "条目 CRC32 校验失败（%@：期望 0x%08x，实际 0x%08x）",
                entry, expected, actual
            )
        case .sizeMismatch(let entry, let expected, let actual):
            return "条目解压长度不匹配（\(entry)：期望 \(expected) 字节，实际 \(actual) 字节）"
        case .invalidZip64Field(let message):
            return "无效的 ZIP64 扩展字段：\(message)"
        case .alreadyFinalized:
            return "ZIP 写入器已完成封包，不能继续写入条目"
        }
    }
}
