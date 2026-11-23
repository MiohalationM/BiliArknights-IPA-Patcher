import IPAPatcherCore
import SwiftUI

struct HostMetadataCard: View {
    let profile: HostIPAProfile
    let isMatched: Bool?

    @State private var showBinaries = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("识别到的宿主信息", systemImage: "app.badge.checkmark")
                    .font(.headline)
                Spacer()
                if let isMatched {
                    statusPill(
                        text: isMatched ? "已匹配" : "不兼容",
                        color: isMatched ? .green : .orange
                    )
                }
            }

            VStack(spacing: 8) {
                infoRow("应用名称", value: profile.displayName)
                infoRow("包名", value: profile.bundleID, monospaced: true)
                infoRow("版本 / 构建号", value: "\(profile.version) (build \(profile.build))", monospaced: true)
                infoRow("加密状态", value: profile.isEncrypted ? "检测到加密" : "已解密 (cryptid=0)", highlight: profile.isEncrypted ? .red : .green)
                infoRow("大小 / 条目数", value: "\(formattedBytes(profile.sourceFileSize)) · \(profile.entryCount) 项")
                if let probe = profile.il2cppProbe {
                    infoRow(
                        "补丁状态",
                        value: probe.detectedInjectedBridge ? "已注入 ABLoginBridge" : "干净未注入",
                        highlight: probe.detectedInjectedBridge ? .orange : .green
                    )
                    infoRow(
                        "IL2CPP 元数据",
                        value: compactProbeSummary(probe)
                    )
                }
            }

            DisclosureGroup(isExpanded: $showBinaries) {
                VStack(alignment: .leading, spacing: 8) {
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
                                    Text("加密")
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
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(.tertiarySystemFill))
                        )
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("已识别的可执行文件（\(profile.binaries.count) 个）")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func compactProbeSummary(_ probe: IL2CPPProbeSummary) -> String {
        if probe.hasGlobalMetadata && probe.globalMetadataIsPlaintext {
            let ver = probe.globalMetadataVersion.map { "v\($0)" } ?? "标准"
            return "明文 \(ver) · 支持自动定位"
        }
        if probe.hasGlobalMetadata {
            return "魔数 \(probe.globalMetadataMagicHex ?? "未知")（非标准明文）"
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

    private func statusPill(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }
}
