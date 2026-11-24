import IPAPatcherCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = PatchPipelineViewModel()
    @State private var isShowingQuickGuide = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let busyNotice = viewModel.incomingBusyNotice {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.orange)
                                .padding(.top, 1)
                            Text(busyNotice)
                                .font(.caption)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 4)
                            Button {
                                viewModel.dismissIncomingBusyNotice()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(Color.orange.opacity(0.14))
                        )
                    }

                    switch viewModel.state {
                    case .idle:
                        HeroActionCard(
                            builtInKit: viewModel.builtInKit,
                            builtInKitError: viewModel.builtInKitCheckError,
                            isCheckingKit: viewModel.isCheckingBuiltInKit,
                            onSelectIPA: { viewModel.openFileImporter() }
                        )

                        PatchOptionsCard(
                            applyCustomBiliIcons: $viewModel.applyCustomBiliIcons,
                            enableAutoAdaptation: $viewModel.enableAutoAdaptation,
                            customProfileCount: viewModel.customProfiles.count,
                            builtInVersionLabel: viewModel.builtInKit?.manifest.version ?? BuiltInKitRepository.activeVersion,
                            onManageProfiles: { viewModel.openProfileManager() }
                        )

                        StorageStatusCard(
                            cachedBytes: viewModel.cachedStorageBytes,
                            hasPendingExport: viewModel.hasPendingExport,
                            hasExportedPendingOutput: viewModel.hasExportedPendingOutput,
                            notice: viewModel.storageNotice,
                            isDisabled: viewModel.state.isProcessing || viewModel.isClearingCache,
                            onRestorePendingExport: { viewModel.restorePendingExportIfPresent() },
                            onClearCache: { viewModel.clearAllLocalCacheManually() }
                        )

                    case .processing(let fileName, let fileSize, let hostProfile, let progress):
                        PipelineProgressCard(
                            fileName: fileName,
                            fileSize: fileSize,
                            progress: progress,
                            onCancel: { viewModel.cancelProcessing() }
                        )

                        if let hostProfile {
                            HostMetadataCard(profile: hostProfile, isMatched: nil)
                        }

                    case .incompatible(_, let hostProfile, let report):
                        MismatchListCard(
                            report: report,
                            onRetry: { viewModel.openFileImporter() },
                            onImportManualProfile: { viewModel.openProfileManager() },
                            onReturnHome: { viewModel.returnToHomeKeepingOutput() }
                        )
                        HostMetadataCard(profile: hostProfile, isMatched: false)

                    case .failed(let fileName, let hostProfile, let title, let message, let technicalDetail):
                        FailedSessionCard(
                            fileName: fileName,
                            title: title,
                            message: message,
                            technicalDetail: technicalDetail,
                            onRetry: { viewModel.openFileImporter() },
                            onReturnHome: { viewModel.returnToHomeKeepingOutput() }
                        )
                        if let hostProfile {
                            HostMetadataCard(profile: hostProfile, isMatched: nil)
                        }

                    case .cancelled(let fileName):
                        cancelledCard(fileName: fileName)

                    case .readyToExport(let result, let exportNotice):
                        ExportReadyCard(
                            result: result,
                            exportedFileName: nil,
                            exportNotice: exportNotice,
                            onExport: { viewModel.presentExporter() },
                            onExportProfileJSON: { profile, noticeHandler in
                                viewModel.exportRuntimeProfileJSON(profile, onNotice: noticeHandler)
                            },
                            onCopyProfileJSON: { profile in
                                viewModel.copyRuntimeProfileJSON(profile)
                            },
                            onDeleteAndFreeSpace: { viewModel.deleteLocalOutputAndFreeSpace() },
                            onSelectAnother: { viewModel.returnToHomeKeepingOutput() }
                        )
                        HostMetadataCard(profile: result.hostProfile, isMatched: true)

                    case .exported(let result, let exportedFileName):
                        ExportReadyCard(
                            result: result,
                            exportedFileName: exportedFileName,
                            exportNotice: nil,
                            onExport: { viewModel.presentExporter() },
                            onExportProfileJSON: { profile, noticeHandler in
                                viewModel.exportRuntimeProfileJSON(profile, onNotice: noticeHandler)
                            },
                            onCopyProfileJSON: { profile in
                                viewModel.copyRuntimeProfileJSON(profile)
                            },
                            onDeleteAndFreeSpace: { viewModel.deleteLocalOutputAndFreeSpace() },
                            onSelectAnother: { viewModel.returnToHomeKeepingOutput() }
                        )
                        HostMetadataCard(profile: result.hostProfile, isMatched: true)
                    }

                    footerNotice
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(AppBackgroundView())
            .navigationTitle("方舟补丁工具")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isShowingQuickGuide = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "questionmark.circle")
                            Text("指南")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(AppTheme.brandCyan)
                    }
                    .accessibilityLabel("使用指南")
                }
            }
            .sheet(isPresented: $isShowingQuickGuide) {
                QuickGuideSheet()
            }
            .sheet(isPresented: $viewModel.isShowingProfileManager) {
                ProfileManagerSheet(
                    customProfiles: viewModel.customProfiles,
                    feedbackMessage: viewModel.profileFeedbackMessage,
                    feedbackIsError: viewModel.profileFeedbackIsError,
                    builtInKit: viewModel.builtInKit,
                    builtInKitError: viewModel.builtInKitCheckError,
                    isCheckingBuiltInKit: viewModel.isCheckingBuiltInKit,
                    isRunningSelfCheck: viewModel.isRunningSelfCheck,
                    selfCheckStatus: viewModel.selfCheckStatus,
                    selfCheckError: viewModel.selfCheckError,
                    selfCheckResult: viewModel.selfCheckResult,
                    onImportProfile: { viewModel.importCustomProfileFromFiles() },
                    onDeleteProfile: { profile in viewModel.deleteCustomProfile(profile) },
                    onRunSelfCheck: { viewModel.runAutoResolverSelfCheckFromFiles() },
                    onCancelSelfCheck: { viewModel.cancelAutoResolverSelfCheck() },
                    onExportResolvedProfile: { profile in viewModel.exportRuntimeProfileJSON(profile) },
                    onCopyResolvedProfile: { profile in viewModel.copyRuntimeProfileJSON(profile) },
                    onRecheckBuiltInKit: { viewModel.verifyBuiltInKitInBackground() }
                )
            }
            .onOpenURL { url in
                viewModel.handleIncomingOpenURL(url)
            }
            .task {
                viewModel.performStartupSetup()
            }
        }
    }

    private func cancelledCard(fileName: String) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                IconBadge(systemName: "stop.circle.fill", color: .secondary, size: 42, iconScale: 0.50)
                VStack(alignment: .leading, spacing: 3) {
                    Text("已取消打包")
                        .font(.headline)
                    Text(fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Text("未完成的临时文件已自动清理，你的原游戏包没有受到任何影响。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                Button {
                    viewModel.openFileImporter()
                } label: {
                    Label("重新选择砸壳 IPA", systemImage: "doc.badge.plus")
                }
                .buttonStyle(AppPrimaryButtonStyle())

                Button {
                    viewModel.returnToHomeKeepingOutput()
                } label: {
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

    private var footerNotice: some View {
        Text("仅支持砸壳 IPA · 导出后需用巨魔或自签安装 · 全程离线不联网")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
            .padding(.bottom, 18)
    }
}

private struct FailedSessionCard: View {
    let fileName: String
    let title: String
    let message: String
    let technicalDetail: String
    let onRetry: () -> Void
    let onReturnHome: () -> Void

    @State private var showErrorTechnicalDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(systemName: "xmark.octagon.fill", color: .red, size: 42, iconScale: 0.50)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup("查看技术诊断详情", isExpanded: $showErrorTechnicalDetails) {
                Text(technicalDetail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.tertiarySystemFill).opacity(0.75))
                    )
                    .padding(.top, 6)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                Button(action: onRetry) {
                    Label("重新选择砸壳 IPA", systemImage: "doc.badge.plus")
                }
                .buttonStyle(AppPrimaryButtonStyle())

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
