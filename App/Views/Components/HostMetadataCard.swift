import IPAPatcherCore
import SwiftUI

struct HostMetadataCard: View {
    let profile: HostIPAProfile
    let isMatched: Bool?

    @State private var showTechnicalDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 9) {
                    IconBadge(systemName: "shippingbox.fill", color: AppTheme.brandCyan, size: 28)
                    Text("游戏包信息")
                        .font(.headline)
                }
                Spacer()
                if let isMatched {
                    StatusPill(
                        text: isMatched ? "可正常适配" : "暂不兼容",
                        color: isMatched ? .green : .orange
                    )
                }
            }

            VStack(spacing: 9) {
                infoRow("游戏名称", value: profile.displayName)
                infoRow("游戏版本", value: "\(profile.version) (Build \(profile.build))", monospaced: true)
                infoRow(
                    "砸壳状态",
                    value: profile.isEncrypted ? "未砸壳（已加密）" : "已砸壳",
                    highlight: profile.isEncrypted ? .red : .green
                )
                if let probe = profile.il2cppProbe {
                    infoRow(
                        "安装包状态",
                        value: probe.detectedInjectedBridge ? "已打过 B 服补丁" : "原版纯净包",
                        highlight: probe.detectedInjectedBridge ? .orange : .green
                    )
                }
                infoRow("文件大小", value: formattedBytes(profile.sourceFileSize))
            }

            DisclosureGroup("查看技术信息与二进制列表", isExpanded: $showTechnicalDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    infoRow("包名 (Bundle ID)", value: profile.bundleID, monospaced: true)
                    infoRow("压缩包条目", value: "\(profile.entryCount) 项")
                    if let probe = profile.il2cppProbe {
                        infoRow("IL2CPP 元数据", value: compactProbeSummary(probe))
                    }

                    Text("可执行文件（\(profile.binaries.count) 个）")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    ForEach(profile.binaries) { binary in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(binary.displayName)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(binary.architectureSummary)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                if binary.isEncrypted {
                                    Text("未砸壳")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.red)
                                }
                            }
                            if let uuid = binary.primaryUUID {
                                Text(uuid)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color(.tertiarySystemFill).opacity(0.75))
                        )
                    }
                }
                .padding(.top, 8)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .appCard(cornerRadius: 20)
    }

    private func compactProbeSummary(_ probe: IL2CPPProbeSummary) -> String {
        if probe.hasGlobalMetadata && probe.globalMetadataIsPlaintext {
            let ver = probe.globalMetadataVersion.map { "v\($0)" } ?? "标准"
            return "明文 \(ver) · 支持自动适配"
        }
        if probe.hasGlobalMetadata {
            return "非常规格式（\(probe.globalMetadataMagicHex ?? "未知")）"
        }
        return "未检测到标准 IL2CPP 元数据"
    }

    private func infoRow(_ label: String, value: String, monospaced: Bool = false, highlight: Color? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption.weight(.medium))
                .foregroundStyle(highlight ?? .primary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }
}
