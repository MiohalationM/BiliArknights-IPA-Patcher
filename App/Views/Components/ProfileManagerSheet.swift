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
    let onRecheckBuiltInKit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showBuiltInDetails = false
    @State private var showSelfCheckOffsets = false
    @State private var copiedTemplateNotice = false

    var body: some View {
        NavigationStack {
            List {
                // Section 1: Manual profile import
                Section {
                    Button(action: onImportProfile) {
                        Label("从「文件」导入手工配置（.json / .plist）", systemImage: "square.and.arrow.down")
                            .font(.subheadline.weight(.medium))
                    }

                    Button {
                        UIPasteboard.general.string = RuntimeOffsetProfile.sampleJSONTemplate
                        copiedTemplateNotice = true
                    } label: {
                        Label(
                            copiedTemplateNotice ? "已复制手工配置 JSON 模板" : "复制手工配置 JSON 模板",
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
                    Text("导入手工适配版（无需更新 App）")
                } footer: {
                    Text("匹配优先级：① 已导入的手工配置 → ② 内置已验证基准（2.7.91）→ ③ 本机自动定位（IL2CPP）。未来有新版手工配置时直接导入即可生效。")
                }

                // Section 2: Saved manual profiles
                Section("已导入的手工配置（\(customProfiles.count)）") {
                    if customProfiles.isEmpty {
                        Text("暂无已导入的手工配置")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(customProfiles) { profile in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.name)
                                        .font(.subheadline.weight(.semibold))
                                    Text("版本 \(profile.version) (build \(profile.build)) · \(profile.revision)")
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
                                    onDeleteProfile(profile)
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

                // Section 3: On-device IL2CPP Auto-Resolver self-check against 2.7.91 ground truth
                Section {
                    Button(action: onRunSelfCheck) {
                        HStack {
                            if isRunningSelfCheck {
                                ProgressView()
                                    .controlSize(.small)
                                Text(selfCheckStatus ?? "正在解析并验算 14 项偏移…")
                                    .font(.subheadline)
                            } else {
                                Label("用 2.7.91 IPA 实机验算自动定位", systemImage: "checkmark.shield")
                                    .font(.subheadline.weight(.medium))
                            }
                        }
                    }
                    .disabled(isRunningSelfCheck)

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
                            Text("实测文件：\(result.fileName)（\(result.hostVersion) / build \(result.hostBuild)，IL2CPP v\(result.metadataVersion)）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if result.isConfirmedCompatible {
                                Text("ABI 字节级校验通过：\(result.abiChecksSummary)")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            } else {
                                ForEach(result.unverifiedReasons, id: \.self) { reason in
                                    Text("未确认兼容：\(reason)")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
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
                    Text("自动定位引擎实机校验")
                } footer: {
                    Text("选择 2.7.91 原版已解密 IPA 后，自动定位器会在不读取内置偏移表的情况下独立解析全部 14 项偏移，并与已验证真值逐项比对。")
                }

                // Section 4: Built-in base kit details (collapsed by default to stay ultra-clean)
                Section("内置已验证基准") {
                    if let kit = builtInKit {
                        HStack {
                            Text("基准版本")
                            Spacer()
                            Text("\(kit.manifest.version) (build \(kit.manifest.build))")
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("底座状态")
                            Spacer()
                            Label("完整（\(kit.payloadEntryCount) 项）", systemImage: "checkmark.seal.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)
                        }
                        DisclosureGroup("技术指纹与重新校验", isExpanded: $showBuiltInDetails) {
                            VStack(alignment: .leading, spacing: 8) {
                                hashRow("修订版本", kit.manifest.revision)
                                hashRow("manifest SHA-256", kit.manifestSHA256)
                                hashRow("payload.zip SHA-256", kit.payloadZipSHA256)
                                Button(action: onRecheckBuiltInKit) {
                                    Label(isCheckingBuiltInKit ? "正在核验…" : "重新核验内置底座", systemImage: "arrow.clockwise")
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
                            Text("正在校验内置底座…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("适配配置管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
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
