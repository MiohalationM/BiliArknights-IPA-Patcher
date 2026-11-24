import IPAPatcherCore
import SwiftUI
import UIKit

struct ProfileManagerSheet: View {
    let customProfiles: [RuntimeOffsetProfile]
    let feedbackMessage: String?
    let feedbackIsError: Bool
    let builtInKit: VerifiedPatchKit?
    let builtInKitError: String?
    let isCheckingBuiltInKit: Bool

    let isRunningSelfCheck: Bool
    let selfCheckStatus: String?
    let selfCheckError: String?
    let selfCheckResult: AutoResolverSelfCheckResult?

    let onImportProfile: () -> Void
    let onDeleteProfile: (RuntimeOffsetProfile) -> Void
    let onRunSelfCheck: () -> Void
    let onCancelSelfCheck: () -> Void
    let onExportResolvedProfile: (RuntimeOffsetProfile) -> Void
    let onCopyResolvedProfile: (RuntimeOffsetProfile) -> Bool
    let onRecheckBuiltInKit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showBuiltInDetails = false
    @State private var showSelfCheckOffsets = false
    @State private var copiedTemplateNotice = false
    @State private var copiedSelfCheckProfile = false
    @State private var profilePendingDelete: RuntimeOffsetProfile?

    var body: some View {
        NavigationStack {
            List {
                // Section 1: Manual profile import for future game updates
                Section {
                    Button(action: onImportProfile) {
                        Label("从「文件」导入配置文件（.json / .plist）", systemImage: "square.and.arrow.down")
                            .font(.subheadline.weight(.medium))
                    }

                    Button {
                        UIPasteboard.general.string = RuntimeOffsetProfile.sampleJSONTemplate
                        copiedTemplateNotice = true
                        Task {
                            try? await Task.sleep(nanoseconds: 2_500_000_000)
                            copiedTemplateNotice = false
                        }
                    } label: {
                        Label(
                            copiedTemplateNotice ? "已复制配置文件 JSON 模板" : "复制配置文件 JSON 模板",
                            systemImage: copiedTemplateNotice ? "checkmark.circle.fill" : "doc.on.doc"
                        )
                        .font(.subheadline)
                        .foregroundStyle(copiedTemplateNotice ? .green : .secondary)
                    }

                    if let feedbackMessage {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: feedbackIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(feedbackIsError ? .orange : .green)
                            Text(feedbackMessage)
                                .font(.caption)
                                .foregroundStyle(feedbackIsError ? .orange : .primary)
                        }
                    }
                } header: {
                    Text("导入新版本配置（无需重装工具）")
                } footer: {
                    Text("游戏大更新且自动适配未生效时，导入社区分享的新版本配置文件即可生效。匹配顺序：① 已导入配置 → ② 内置 2.7.91 → ③ 自动适配。")
                }

                // Section 2: Saved manual profiles
                Section("已导入的配置文件（\(customProfiles.count)）") {
                    if customProfiles.isEmpty {
                        Text("暂无已导入的配置文件")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(customProfiles) { profile in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.name)
                                        .font(.subheadline.weight(.semibold))
                                    Text("游戏版本 \(profile.version) (Build \(profile.build)) · \(profile.revision)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Text("Unity UUID: \(profile.unityUUID)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 4)
                                Button(role: .destructive) {
                                    profilePendingDelete = profile
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.subheadline)
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("删除配置 \(profile.name)")
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                // Section 3: Advanced developer self-check tool
                Section {
                    if isRunningSelfCheck {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text(selfCheckStatus ?? "正在验算 14 项关键偏移…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("取消", role: .destructive, action: onCancelSelfCheck)
                                .font(.caption.weight(.semibold))
                        }
                    } else {
                        Button(action: onRunSelfCheck) {
                            Label("用 2.7.91 砸壳 IPA 实机验算自动适配", systemImage: "checkmark.shield")
                                .font(.subheadline.weight(.medium))
                        }
                    }

                    if let selfCheckError {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "xmark.octagon.fill")
                                .foregroundStyle(.red)
                            Text(selfCheckError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    if let result = selfCheckResult {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: result.allMatched ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(result.allMatched ? .green : .orange)
                                Text("\(result.matchedCount)/\(result.totalCount) 项与 2.7.91 基准一致")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(String(format: "%.1fs", result.durationSeconds))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text("实测文件：\(result.fileName)（\(result.hostVersion) / Build \(result.hostBuild)，IL2CPP v\(result.metadataVersion)）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if result.isConfirmedCompatible {
                                Text("数据结构校验通过：\(result.abiChecksSummary)")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            } else {
                                ForEach(result.unverifiedReasons, id: \.self) { reason in
                                    Text("未确认兼容：\(reason)")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }

                            if let resolvedProfile = result.resolvedProfile {
                                HStack(spacing: 8) {
                                    Button {
                                        onExportResolvedProfile(resolvedProfile)
                                    } label: {
                                        Label("导出 JSON", systemImage: "square.and.arrow.up")
                                            .font(.caption.weight(.medium))
                                    }
                                    .buttonStyle(.bordered)

                                    Button {
                                        if onCopyResolvedProfile(resolvedProfile) {
                                            copiedSelfCheckProfile = true
                                            Task {
                                                try? await Task.sleep(nanoseconds: 2_500_000_000)
                                                copiedSelfCheckProfile = false
                                            }
                                        }
                                    } label: {
                                        Label(
                                            copiedSelfCheckProfile ? "已复制" : "复制 JSON",
                                            systemImage: copiedSelfCheckProfile ? "checkmark.circle.fill" : "doc.on.doc"
                                        )
                                        .font(.caption.weight(.medium))
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(copiedSelfCheckProfile ? .green : .accentColor)
                                }
                            }

                            DisclosureGroup("展开 14 项偏移对照详情", isExpanded: $showSelfCheckOffsets) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(result.comparisons, id: \.id) { item in
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Image(systemName: item.isMatch ? "checkmark.circle.fill" : "xmark.circle.fill")
                                                .font(.caption2)
                                                .foregroundStyle(item.isMatch ? Color.green : Color.red)
                                            Text(item.key)
                                                .font(.caption2.monospaced())
                                                .lineLimit(1)
                                            Spacer()
                                            Text(IL2CPPOffsetSet.hexString(item.resolved))
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(item.isMatch ? Color.primary : Color.red)
                                        }
                                    }
                                }
                                .padding(.top, 6)
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("高级自检（普通玩家无需操作）")
                } footer: {
                    Text("仅供验算测试：选择 2.7.91 原版砸壳 IPA 后，将独立分析 14 项关键偏移并与已验证基准逐项比对。")
                }

                // Section 4: Built-in base kit details
                Section("内置补丁组件") {
                    if let kit = builtInKit {
                        HStack {
                            Text("内置支持版本")
                            Spacer()
                            Text("\(kit.manifest.version) (Build \(kit.manifest.build))")
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("组件完整性")
                            Spacer()
                            Label("正常（\(kit.payloadEntryCount) 项）", systemImage: "checkmark.seal.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)
                        }
                        DisclosureGroup("校验指纹与重新核验", isExpanded: $showBuiltInDetails) {
                            VStack(alignment: .leading, spacing: 8) {
                                hashRow("修订版本", kit.manifest.revision)
                                hashRow("manifest SHA-256", kit.manifestSHA256)
                                hashRow("payload.zip SHA-256", kit.payloadZipSHA256)
                                Button(action: onRecheckBuiltInKit) {
                                    Label(isCheckingBuiltInKit ? "正在核验…" : "重新校验组件完整性", systemImage: "arrow.clockwise")
                                        .font(.footnote.weight(.medium))
                                }
                                .disabled(isCheckingBuiltInKit)
                                .padding(.top, 4)
                            }
                            .padding(.vertical, 6)
                        }
                        .font(.subheadline)
                    } else if let builtInKitError {
                        Text("自检异常：\(builtInKitError)")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button("重试自检", action: onRecheckBuiltInKit)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在检查内置补丁组件…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("版本配置与高级工具")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .alert(
                "确认删除这份配置文件？",
                isPresented: Binding(
                    get: { profilePendingDelete != nil },
                    set: { if !$0 { profilePendingDelete = nil } }
                )
            ) {
                if let target = profilePendingDelete {
                    Button("删除「\(target.name)」", role: .destructive) {
                        onDeleteProfile(target)
                        profilePendingDelete = nil
                    }
                }
                Button("取消", role: .cancel) {
                    profilePendingDelete = nil
                }
            } message: {
                if let target = profilePendingDelete {
                    Text("将移除本地保存的 \(target.version) (Build \(target.build)) 配置文件，后续可随时重新导入。")
                }
            }
        }
    }

    private func hashRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
        }
    }
}
