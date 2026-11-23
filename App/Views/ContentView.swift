import IPAPatcherCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var viewModel = PatchPipelineViewModel()
    @State private var showErrorTechnicalDetails = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
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
                            notice: viewModel.storageNotice,
                            isDisabled: viewModel.state.isProcessing,
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
                            onImportManualProfile: { viewModel.openProfileManager() }
                        )
                        HostMetadataCard(profile: hostProfile, isMatched: false)

                    case .failed(let fileName, let hostProfile, let title, let message, let technicalDetail):
                        failedCard(
                            fileName: fileName,
                            title: title,
                            message: message,
                            technicalDetail: technicalDetail
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
                            onDeleteAndFreeSpace: { viewModel.deleteLocalOutputAndFreeSpace() },
                            onSelectAnother: { viewModel.returnToHomeKeepingOutput() }
                        )
                        HostMetadataCard(profile: result.hostProfile, isMatched: true)
                    }

                    footerNotice
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("方舟补丁工具")
            .navigationBarTitleDisplayMode(.large)
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

    private func failedCard(
        fileName: String,
        title: String,
        message: String,
        technicalDetail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)

            DisclosureGroup("技术诊断信息", isExpanded: $showErrorTechnicalDetails) {
                Text(technicalDetail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                    )
                    .padding(.top, 4)
            }
            .font(.footnote)

            VStack(spacing: 10) {
                Button {
                    viewModel.openFileImporter()
                } label: {
                    Label("重新选择 IPA", systemImage: "doc.badge.plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    viewModel.returnToHomeKeepingOutput()
                } label: {
                    Text("返回首页")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func cancelledCard(fileName: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "stop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("已取消处理")
                        .font(.headline)
                    Text(fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("所有未完成的临时输出已自动清理，原始 IPA 未被修改。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                Button {
                    viewModel.openFileImporter()
                } label: {
                    Label("重新选择 IPA", systemImage: "doc.badge.plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    viewModel.returnToHomeKeepingOutput()
                } label: {
                    Text("返回首页")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var footerNotice: some View {
        Text("仅处理已解密 IPA · 输出待签名 IPA · 全程离线不联网")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
            .padding(.bottom, 16)
    }
}
