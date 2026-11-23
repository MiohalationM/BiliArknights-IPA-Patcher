import IPAPatcherCore
import SwiftUI

struct ExportReadyCard: View {
    let result: PatchExecutionResult
    let exportedFileName: String?
    let exportNotice: String?
    let onExport: () -> Void
    let onDeleteAndFreeSpace: () -> Void
    let onSelectAnother: () -> Void

    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: exportedFileName != nil ? "checkmark.circle.fill" : "checkmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(exportedFileName != nil ? "已保存待签名 IPA" : "复核通过，可导出")
                            .font(.headline)
                        adaptationBadge
                    }
                    Text("成品已安全暂存在本机（切出去清空间重启也不会被误删），确认导出无误后可随时手动删除释放空间。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let exportedFileName {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill.badge.checkmark")
                        .foregroundStyle(.green)
                    Text("系统已确认保存：\(exportedFileName)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.green)
                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.green.opacity(0.12))
                )
            } else if let exportNotice {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.orange)
                    Text(exportNotice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                )
            }

            // 2x2 Key Metrics Grid
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                statTile(title: "本地暂存", value: formattedBytes(result.outputBytes))
                statTile(title: "处理耗时", value: String(format: "%.1f 秒", result.durationSeconds))
                statTile(title: "适配方式", value: result.adaptationMode.badgeTitle)
                statTile(title: "应用图标", value: result.appliedCustomBiliIcons ? "B 服图标" : "保留原版")
            }

            VStack(spacing: 8) {
                metricRow("输出文件名", value: result.suggestedExportFilename, monospaced: true)
                metricRow("目标版本", value: "\(result.hostProfile.version) (build \(result.hostProfile.build))", monospaced: true)
                metricRow("补丁修订", value: result.revision, monospaced: true)
                metricRow(
                    "条目统计",
                    value: "保留 \(result.preservedSourceFiles) · 替换 \(result.modifiedEntries.count) · 新增 \(result.addedEntries.count) · 移除 \(result.removedEntries.count)"
                )
            }

            VStack(spacing: 10) {
                Button(action: onExport) {
                    Label(
                        exportedFileName != nil ? "再次导出到「文件」" : "导出待签名 IPA",
                        systemImage: "square.and.arrow.up"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("删除本地暂存成品（释放 \(formattedBytes(result.outputBytes))）", systemImage: "trash")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button(action: onSelectAnother) {
                    Text("返回首页")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .confirmationDialog(
            "删除本地暂存成品？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认删除并释放 \(formattedBytes(result.outputBytes))", role: .destructive) {
                onDeleteAndFreeSpace()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(exportedFileName != nil
                ? "你已将其导出至「文件」。删除本地暂存不会影响已导出的 IPA，也不会影响原始 IPA。"
                : "你尚未完成系统导出。如果现在删除，下次需要重新处理该 IPA。")
        }
    }

    private var adaptationBadge: some View {
        let color: Color = {
            switch result.adaptationMode {
            case .builtInVerified: return .green
            case .manualCustomProfile: return .blue
            case .autoResolved: return .indigo
            }
        }()
        return Text(result.adaptationMode.badgeTitle)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private func statTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
    }

    private func metricRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption.weight(.medium))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }
}
