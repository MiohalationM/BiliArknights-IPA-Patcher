import SwiftUI

struct StorageStatusCard: View {
    let cachedBytes: UInt64
    let hasPendingExport: Bool
    let hasExportedPendingOutput: Bool
    let notice: String?
    let isDisabled: Bool
    let onRestorePendingExport: () -> Void
    let onClearCache: () -> Void

    @State private var showConfirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                if cachedBytes > 0 {
                    IconBadge(
                        systemName: "internaldrive.fill",
                        color: hasExportedPendingOutput ? AppTheme.brandCyan : .orange,
                        size: 32
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hasExportedPendingOutput
                             ? "已导出的暂存包（\(formattedBytes(cachedBytes))）"
                             : "待导出的 B 服 IPA（\(formattedBytes(cachedBytes))）")
                            .font(.subheadline.weight(.semibold))
                        Text(hasExportedPendingOutput
                             ? "已保存到「文件」，确认安装没问题后可随时删除省空间"
                             : "还未导出 · 已安全暂存在本机，退出清理空间也不会丢失")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                    Text("暂无缓存文件，不占用额外空间")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            if let notice {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if cachedBytes > 0 || hasPendingExport {
                HStack(spacing: 10) {
                    if hasPendingExport {
                        Button(action: onRestorePendingExport) {
                            Label(
                                hasExportedPendingOutput ? "查看 / 再导出" : "继续导出",
                                systemImage: "square.and.arrow.up"
                            )
                        }
                        .buttonStyle(AppPrimaryButtonStyle(compact: true))
                    }

                    Button(role: .destructive) {
                        showConfirmDelete = true
                    } label: {
                        Label("删除省空间", systemImage: "trash")
                    }
                    .buttonStyle(AppSecondaryButtonStyle(tint: .red, compact: true))
                    .disabled(isDisabled)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, cachedBytes > 0 || notice != nil ? 16 : 14)
        .appCard(cornerRadius: 18)
        .alert(
            "清理本地暂存文件？",
            isPresented: $showConfirmDelete
        ) {
            Button("确认清理（释放 \(formattedBytes(cachedBytes))）", role: .destructive) {
                onClearCache()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅清理本工具内暂存的成品与缓存，不会影响你已经导出到「文件」的 IPA，也不会影响原游戏包。")
        }
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }
}
