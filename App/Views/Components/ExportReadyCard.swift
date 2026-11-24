import IPAPatcherCore
import SwiftUI

struct ExportReadyCard: View {
    let result: PatchExecutionResult
    let exportedFileName: String?
    let exportNotice: String?
    let onExport: () -> Void
    let onExportProfileJSON: (RuntimeOffsetProfile, @escaping (String, Bool) -> Void) -> Void
    let onCopyProfileJSON: (RuntimeOffsetProfile) -> Bool
    let onDeleteAndFreeSpace: () -> Void
    let onSelectAnother: () -> Void

    @State private var showDeleteConfirmation = false
    @State private var showTechnicalSummary = false
    @State private var profileShareNotice: String?
    @State private var profileShareIsError = false
    @State private var copiedAutoProfile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Success header
            HStack(alignment: .center, spacing: 12) {
                IconBadge(
                    systemName: exportedFileName != nil ? "checkmark.circle.fill" : "checkmark.seal.fill",
                    color: .green,
                    size: 44,
                    iconScale: 0.52
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(exportedFileName != nil ? "已保存到「文件」" : "打包完成")
                            .font(.headline)
                        adaptationBadge
                    }
                    Text("安装包已通过完整性校验，安全暂存在本机。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            // Exported confirmation or notice
            if let exportedFileName {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("已保存为：\(exportedFileName)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.green)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.green.opacity(0.12))
                )
            } else if let exportNotice {
                HStack(alignment: .top, spacing: 8) {
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

            // Clear player next-step callout
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hand.tap.fill")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.brandCyan)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("下一步怎么安装？")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(exportedFileName != nil
                         ? "文件已保存到「文件」，直接用巨魔商店（TrollStore）或自签工具安装即可；打开游戏在启动页点右上角按钮即可切到 B 服登录。"
                         : "点下方按钮导出 IPA 后，用巨魔商店（TrollStore）或自签工具安装；打开游戏在启动页点右上角按钮即可切到 B 服登录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(AppTheme.brandCyan.opacity(0.09))
            )

            // Clean 2x2 Key Metrics Grid
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                statTile(icon: "internaldrive", title: "安装包大小", value: formattedBytes(result.outputBytes))
                statTile(icon: "clock", title: "处理耗时", value: String(format: "%.1f 秒", result.durationSeconds))
                statTile(icon: "tag", title: "游戏版本", value: result.hostProfile.version)
                statTile(icon: "app.badge", title: "桌面图标", value: result.appliedCustomBiliIcons ? "B 服图标" : "保留原版")
            }

            // Collapsible technical packaging details
            DisclosureGroup("查看打包详情", isExpanded: $showTechnicalSummary) {
                VStack(spacing: 8) {
                    metricRow("输出文件名", value: result.suggestedExportFilename, monospaced: true)
                    metricRow("完整版本", value: "\(result.hostProfile.version) (Build \(result.hostProfile.build))", monospaced: true)
                    metricRow("适配方式", value: result.adaptationMode.detailTitle)
                    metricRow("补丁版本", value: result.revision, monospaced: true)
                    metricRow(
                        "文件改动",
                        value: "保留 \(result.preservedSourceFiles) · 更新 \(result.modifiedEntries.count) · 新增 \(result.addedEntries.count)"
                    )
                }
                .padding(.top, 8)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)

            // Auto-adapted new version shareable profile box
            if let autoProfile = result.generatedRuntimeProfile {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.indigo)
                        Text("已自动生成新版本配置文件，可导出分享给其他玩家：")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button {
                            onExportProfileJSON(autoProfile) { msg, isErr in
                                profileShareNotice = msg
                                profileShareIsError = isErr
                            }
                        } label: {
                            Label("导出配置 JSON", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(AppSecondaryButtonStyle(tint: .indigo, compact: true))

                        Button {
                            if onCopyProfileJSON(autoProfile) {
                                copiedAutoProfile = true
                                Task {
                                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                                    copiedAutoProfile = false
                                }
                            }
                        } label: {
                            Label(
                                copiedAutoProfile ? "已复制 JSON" : "复制 JSON",
                                systemImage: copiedAutoProfile ? "checkmark.circle.fill" : "doc.on.doc"
                            )
                        }
                        .buttonStyle(
                            AppSecondaryButtonStyle(
                                tint: copiedAutoProfile ? .green : .indigo,
                                compact: true
                            )
                        )
                    }
                    if let profileShareNotice {
                        Text(profileShareNotice)
                            .font(.caption2)
                            .foregroundStyle(profileShareIsError ? .orange : .green)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.indigo.opacity(0.08))
                )
            }

            // Primary & secondary actions
            VStack(spacing: 10) {
                Button(action: onExport) {
                    Label(
                        exportedFileName != nil ? "再次导出 B 服 IPA" : "导出 B 服 IPA",
                        systemImage: "square.and.arrow.up"
                    )
                }
                .buttonStyle(AppPrimaryButtonStyle())

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("清理暂存文件（释放 \(formattedBytes(result.outputBytes))）", systemImage: "trash")
                }
                .buttonStyle(AppSecondaryButtonStyle(tint: .red))

                Button(action: onSelectAnother) {
                    Text("返回首页")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            }
        }
        .padding(20)
        .appCard(cornerRadius: 22)
        .alert(
            "清理本地暂存文件？",
            isPresented: $showDeleteConfirmation
        ) {
            Button("确认清理（释放 \(formattedBytes(result.outputBytes))）", role: .destructive) {
                onDeleteAndFreeSpace()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(exportedFileName != nil
                ? "你已将安装包保存到「文件」。清理本地暂存不会影响已导出的文件，也不会改动原游戏包。"
                : "你还没有导出这份安装包。如果现在清理，下次需要重新打包。")
        }
    }

    private var adaptationBadge: some View {
        let color: Color = {
            switch result.adaptationMode {
            case .builtInVerified: return .green
            case .manualCustomProfile: return AppTheme.brandCyan
            case .autoResolved: return .indigo
            }
        }()
        return StatusPill(text: result.adaptationMode.badgeTitle, color: color)
    }

    private func statTile(icon: String, title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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
                .fill(Color(.tertiarySystemFill).opacity(0.75))
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
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }
}
