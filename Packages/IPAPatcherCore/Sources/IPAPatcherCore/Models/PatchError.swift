import Foundation
import Zip64Kit

public enum PatchError: Error, LocalizedError, Sendable {
    case zipFailure(ZipError)
    case missingAppBundle(foundCount: Int)
    case invalidInfoPlist(String)
    case missingExecutable(String)
    case invalidMachO(binaryPath: String, reason: String)
    case missingBuiltInKit(String)
    case lockedManifestHashMismatch(expected: String, actual: String)
    case unsupportedManifestProfile(String)
    case payloadZipHashMismatch(expected: String, actual: String)
    case payloadEntryMismatch(String)
    case patchPathOutsideAppRoot(String)
    case encryptedHostIPA(binaries: [String])
    case incompatibleHost(IncompatibilityReport)
    case alreadyInjected(binaryPath: String, dylibPath: String)
    case machOInjectionFailed(binaryPath: String, reason: String)
    case invalidCustomProfile(String)
    case autoResolutionFailed(String)
    case preimageMismatch(binaryPath: String, offset: Int)
    case invalidPatchedMetadata(String)
    case encryptedOutputBinary(String)
    case outputVerificationFailed(String)
    case insufficientDiskSpace(requiredBytes: UInt64, availableBytes: UInt64)
    case outputAlreadyExists(String)
    case fileAccessDenied(String)
    case ioFailure(String)

    public var userTitle: String {
        switch self {
        case .zipFailure:
            return "IPA 压缩包格式异常"
        case .missingAppBundle:
            return "未识别到有效的 App 目录"
        case .invalidInfoPlist:
            return "Info.plist 解析失败"
        case .missingExecutable:
            return "缺少必需的可执行文件"
        case .invalidMachO:
            return "二进制文件结构异常"
        case .missingBuiltInKit, .lockedManifestHashMismatch, .unsupportedManifestProfile,
             .payloadZipHashMismatch, .payloadEntryMismatch, .patchPathOutsideAppRoot:
            return "内置补丁包校验失败"
        case .encryptedHostIPA:
            return "检测到加密的 IPA"
        case .incompatibleHost:
            return "当前 IPA 版本不兼容"
        case .alreadyInjected:
            return "该 IPA 已经打过补丁"
        case .machOInjectionFailed:
            return "Mach-O 动态注入预检未通过"
        case .invalidCustomProfile:
            return "手工适配配置无效"
        case .autoResolutionFailed:
            return "自动定位 IL2CPP 偏移未通过"
        case .preimageMismatch:
            return "补丁位置原始字节不匹配"
        case .invalidPatchedMetadata, .encryptedOutputBinary:
            return "补丁元数据校验失败"
        case .outputVerificationFailed:
            return "输出复核未通过"
        case .insufficientDiskSpace:
            return "设备可用存储空间不足"
        case .outputAlreadyExists:
            return "目标输出文件已存在"
        case .fileAccessDenied:
            return "无法访问所选文件"
        case .ioFailure:
            return "文件读写失败"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .zipFailure(let err):
            return err.localizedDescription
        case .missingAppBundle(let count):
            return "IPA 顶层 Payload/ 下应仅包含 1 个 .app/Info.plist，实际检测到 \(count) 个。"
        case .invalidInfoPlist(let detail):
            return "无法读取应用 Info.plist：\(detail)"
        case .missingExecutable(let path):
            return "IPA 中缺少可执行文件：\(path)"
        case .invalidMachO(let path, let reason):
            return "解析 Mach-O 失败（\(path)）：\(reason)"
        case .missingBuiltInKit(let detail):
            return "内置补丁资源缺失：\(detail)"
        case .lockedManifestHashMismatch(let expected, let actual):
            return "内置 manifest.json 哈希校验未通过（期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…）。"
        case .unsupportedManifestProfile(let detail):
            return "内置补丁配置不受支持：\(detail)"
        case .payloadZipHashMismatch(let expected, let actual):
            return "内置 payload.zip 哈希校验未通过（期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…）。"
        case .payloadEntryMismatch(let detail):
            return "内置补丁条目指纹不匹配：\(detail)"
        case .patchPathOutsideAppRoot(let path):
            return "补丁条目超出主应用目录范围：\(path)"
        case .encryptedHostIPA(let binaries):
            let list = binaries.prefix(3).joined(separator: "、")
            return "该 IPA 包含未解密的加密二进制（\(list)）。本工具仅支持已解密 IPA，不执行解密。"
        case .incompatibleHost(let report):
            return report.summaryText
        case .alreadyInjected(let binaryPath, let dylibPath):
            let binName = URL(fileURLWithPath: binaryPath).lastPathComponent
            return "\(binName) 中已存在 \(dylibPath) 加载命令，说明该 IPA 此前已经注入过补丁，请选择未修补过的原始解密 IPA。"
        case .machOInjectionFailed(let binaryPath, let reason):
            let binName = URL(fileURLWithPath: binaryPath).lastPathComponent
            return "无法向 \(binName) 自动注入桥接库：\(reason)"
        case .invalidCustomProfile(let detail):
            return "手工适配配置校验失败：\(detail)"
        case .autoResolutionFailed(let detail):
            return "本机自动定位 IL2CPP 偏移失败：\(detail)"
        case .preimageMismatch(let binaryPath, let offset):
            return "目标二进制 \(binaryPath) 在偏移 0x\(String(offset, radix: 16)) 处的原始字节与补丁预期不一致，可能已打过补丁或不属于匹配的构建版本。"
        case .invalidPatchedMetadata(let detail):
            return "补丁应用后的 Info.plist 校验失败：\(detail)"
        case .encryptedOutputBinary(let path):
            return "输出二进制仍带加密标记：\(path)"
        case .outputVerificationFailed(let detail):
            return "重打包后的输出复核未通过：\(detail)"
        case .insufficientDiskSpace(let required, let available):
            let reqStr = ByteCountFormatter.string(fromByteCount: Int64(min(required, UInt64(Int64.max))), countStyle: .file)
            let availStr = ByteCountFormatter.string(fromByteCount: Int64(min(available, UInt64(Int64.max))), countStyle: .file)
            return "预计需要至少 \(reqStr) 可用空间，当前仅剩 \(availStr)，请清理空间后重试。"
        case .outputAlreadyExists(let path):
            return "目标位置已存在同名成品文件：\(URL(fileURLWithPath: path).lastPathComponent)。为防止覆盖已有结果，本次已停止；如需覆盖请清理旧文件或显式允许覆盖。"
        case .fileAccessDenied(let detail):
            return "无法获取所选文件的访问权限：\(detail)"
        case .ioFailure(let detail):
            return "文件操作失败：\(detail)"
        }
    }
}
