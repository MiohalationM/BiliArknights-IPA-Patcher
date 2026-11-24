import IPAPatcherCore
import SwiftUI

struct MismatchListCard: View {
    let report: IncompatibilityReport
    let onRetry: () -> Void
    let onImportManualProfile: () -> Void
    let onReturnHome: () -> Void

    @State private var showDiagnosticDetails = false

    private var isWrongApp: Bool {
        !report.isEncrypted && report.mismatches.contains(where: { $0.kind == .bundleID })
    }

    private var friendlyTitle: String {
        if report.isEncrypted {
            return "这个 IPA 还没砸壳"
        }
        if isWrongApp {
            return "这不是《明日方舟》官服安装包"
        }
        return "当前版本暂未能自动适配"
    }

    private var friendlyDescription: String {
        if report.isEncrypted {
            return "检测到游戏文件仍处于加密状态，无法直接打补丁。请先获取已砸壳的《明日方舟》官服 IPA 后再导入。"
        }
        if isWrongApp {
            return "当前工具仅支持为《明日方舟》国服官方砸壳 IPA 打 B 服补丁，请确认是否选错了安装包。"
        }
        return report.summaryText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(
                    systemName: report.isEncrypted ? "lock.shield.fill" : "exclamationmark.triangle.fill",
                    color: report.isEncrypted ? .red : .orange,
                    size: 42,
                    iconScale: 0.50
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(friendlyTitle)
                        .font(.headline)
                    Text(friendlyDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !report.isEncrypted && !isWrongApp {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .font(.caption)
                        .foregroundStyle(AppTheme.brandCyan)
                        .padding(.top, 2)
                    Text("解决方法：可以直接导入新版手工配置文件（.json / .plist），无需等待或重装本工具。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(AppTheme.brandCyan.opacity(0.08))
                )
            }

            DisclosureGroup("查看详细诊断信息（共 \(report.mismatches.count) 项）", isExpanded: $showDiagnosticDetails) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(report.mismatches) { mismatch in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(mismatch.fieldLabel)
                                .font(.caption.weight(.semibold))

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .top, spacing: 6) {
                                    Text("期望:")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 32, alignment: .leading)
                                    Text(mismatch.expected)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
                                }
                                HStack(alignment: .top, spacing: 6) {
                                    Text("实际:")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 32, alignment: .leading)
                                    Text(mismatch.actual)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.red)
                                        .textSelection(.enabled)
                                }
                            }

                            Text(mismatch.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color(.tertiarySystemFill).opacity(0.75))
                        )
                    }
                }
                .padding(.top, 8)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                Button(action: onRetry) {
                    Label("重新选择砸壳 IPA", systemImage: "doc.badge.plus")
                }
                .buttonStyle(AppPrimaryButtonStyle())

                if !report.isEncrypted && !isWrongApp {
                    Button(action: onImportManualProfile) {
                        Label("导入新版配置文件（.json / .plist）", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(AppSecondaryButtonStyle(tint: AppTheme.brandCyan))
                }

                Button(action: onReturnHome) {
                    Text("返回首页")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            }
        }
        .padding(20)
        .appCard(cornerRadius: 22)
    }
}
