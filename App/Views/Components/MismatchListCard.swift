import IPAPatcherCore
import SwiftUI

struct MismatchListCard: View {
    let report: IncompatibilityReport
    let onRetry: () -> Void
    let onImportManualProfile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: report.isEncrypted ? "lock.shield.fill" : "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(report.isEncrypted ? .red : .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.isEncrypted ? "检测到加密的 IPA" : "暂未匹配到兼容适配配置")
                        .font(.headline)
                    Text(report.summaryText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("诊断详情（共 \(report.mismatches.count) 项）")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(report.mismatches) { mismatch in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(mismatch.fieldLabel)
                            .font(.subheadline.weight(.semibold))

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .top, spacing: 6) {
                                Text("期望:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .leading)
                                Text(mismatch.expected)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                            }
                            HStack(alignment: .top, spacing: 6) {
                                Text("实际:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .leading)
                                Text(mismatch.actual)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                        }

                        Text(mismatch.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                    )
                }
            }

            VStack(spacing: 10) {
                Button(action: onRetry) {
                    Label("重新选择 IPA", systemImage: "doc.badge.plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                if !report.isEncrypted {
                    Button(action: onImportManualProfile) {
                        Label("导入手工适配配置（.json / .plist）", systemImage: "square.and.arrow.down")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}
