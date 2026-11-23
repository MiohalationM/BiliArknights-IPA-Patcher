import SwiftUI

struct StorageStatusCard: View {
    let cachedBytes: UInt64
    let hasPendingExport: Bool
    let notice: String?
    let isDisabled: Bool
    let onRestorePendingExport: () -> Void
    let onClearCache: () -> Void

    @State private var showConfirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: cachedBytes > 0 ? "internaldrive.fill" : "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(cachedBytes > 0 ? Color.orange : Color.green)

                if cachedBytes > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本地暂存成品 \(formattedBytes(cachedBytes))")
                            .font(.subheadline.weight(.semibold))
                        Text("已排除 iCloud 备份，切出去清空间重启也不会误删")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("本地缓存 0 B · 无残留临时文件")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if cachedBytes > 0 || hasPendingExport {
                HStack(spacing: 10) {
                    if hasPendingExport {
                        Button(action: onRestorePendingExport) {
                            Label("继续导出", systemImage: "square.and.arrow.up")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button(role: .destructive) {
                        showConfirmDelete = true
                    } label: {
                        Label("删除缓存", systemImage: "trash")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(isDisabled)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, cachedBytes > 0 || notice != nil ? 16 : 13)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .confirmationDialog(
            "删除本地成品与全部缓存？",
            isPresented: $showConfirmDelete,
            titleVisibility: .visible
        ) {
            Button("确认删除并释放 \(formattedBytes(cachedBytes))", role: .destructive) {
                onClearCache()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅删除本工具沙盒内的暂存成品与临时缓存，不会影响你已导出到「文件」的 IPA 或原始 IPA。")
        }
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }
}
