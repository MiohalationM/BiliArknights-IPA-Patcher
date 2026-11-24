import Foundation
import IPAPatcherCore
import UIKit

enum SystemExportResult: Sendable {
    case saved([URL])
    case cancelled
    case failed(String)
}

struct AutoResolverSelfCheckResult: Equatable, Sendable {
    let fileName: String
    let hostVersion: String
    let hostBuild: String
    let metadataVersion: Int
    let durationSeconds: TimeInterval
    let isConfirmedCompatible: Bool
    let abiChecksSummary: String
    let unverifiedReasons: [String]
    let comparisons: [IL2CPPOffsetComparison]
    let resolvedProfile: RuntimeOffsetProfile?

    var matchedCount: Int {
        comparisons.filter(\.isMatch).count
    }

    var totalCount: Int {
        comparisons.count
    }

    var allMatched: Bool {
        isConfirmedCompatible && matchedCount == totalCount && totalCount > 0
    }
}

@MainActor
final class PatchPipelineViewModel: ObservableObject {
    private static let iconPrefKey = "ArknightsPatcher.applyCustomBiliIcons"
    private static let autoAdaptPrefKey = "ArknightsPatcher.enableAutoAdaptation"

    @Published var state: PatchSessionState = .idle
    @Published var isShowingProfileManager: Bool = false

    // User preferences (persisted in UserDefaults)
    @Published var applyCustomBiliIcons: Bool {
        didSet { UserDefaults.standard.set(applyCustomBiliIcons, forKey: Self.iconPrefKey) }
    }
    @Published var enableAutoAdaptation: Bool {
        didSet { UserDefaults.standard.set(enableAutoAdaptation, forKey: Self.autoAdaptPrefKey) }
    }

    var currentPatchOptions: PatchOptions {
        PatchOptions(
            applyCustomBiliIcons: applyCustomBiliIcons,
            enableAutoAdaptation: enableAutoAdaptation
        )
    }

    // Built-in base kit state
    @Published private(set) var builtInKit: VerifiedPatchKit?
    @Published private(set) var builtInKitCheckError: String?
    @Published private(set) var isCheckingBuiltInKit: Bool = false

    // Imported manual profiles state
    @Published private(set) var customProfiles: [RuntimeOffsetProfile] = []
    @Published private(set) var profileFeedbackMessage: String?
    @Published private(set) var profileFeedbackIsError: Bool = false

    // On-device 2.7.91 auto-resolver self-check state
    @Published private(set) var isRunningSelfCheck: Bool = false
    @Published private(set) var selfCheckStatus: String?
    @Published private(set) var selfCheckError: String?
    @Published private(set) var selfCheckResult: AutoResolverSelfCheckResult?

    // Local cache & pending export state (all published so SwiftUI always updates reliably)
    @Published private(set) var cachedStorageBytes: UInt64 = 0
    @Published private(set) var storageNotice: String?
    @Published private(set) var incomingBusyNotice: String?
    @Published private(set) var isClearingCache: Bool = false
    @Published private var activePendingRecord: PendingExportRecord?

    private let documentPickerPresenter = SystemDocumentPickerPresenter()
    private var hasPerformedStartup: Bool = false
    private var startupCleanupTask: Task<Void, Never>?
    private var activeTask: Task<Void, Never>?
    private var selfCheckTask: Task<Void, Never>?
    private var currentTransientDirectory: URL?
    private var activeSourceURL: URL?
    private var activeBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var selfCheckBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.iconPrefKey) != nil {
            self.applyCustomBiliIcons = defaults.bool(forKey: Self.iconPrefKey)
        } else {
            self.applyCustomBiliIcons = true
        }
        if defaults.object(forKey: Self.autoAdaptPrefKey) != nil {
            self.enableAutoAdaptation = defaults.bool(forKey: Self.autoAdaptPrefKey)
        } else {
            self.enableAutoAdaptation = true
        }
    }

    var hasPendingExport: Bool {
        activePendingRecord != nil
    }

    var hasExportedPendingOutput: Bool {
        activePendingRecord?.exportedFileName != nil
    }

    func performStartupSetup() {
        guard !hasPerformedStartup else { return }
        hasPerformedStartup = true

        // Never delete an active session or inbox copy if cold-start `onOpenURL` already started processing.
        let excludedSession = currentTransientDirectory
        let excludedInbox = activeSourceURL
        let isCurrentlyIdle = (state == .idle)

        reloadCustomProfiles()
        if let restored = TempWorkspaceManager.loadPendingExport() {
            activePendingRecord = restored
            if isCurrentlyIdle {
                if let exportedName = restored.exportedFileName {
                    state = .exported(result: restored.result, exportedFileName: exportedName)
                } else {
                    state = .readyToExport(
                        result: restored.result,
                        exportNotice: "已恢复上次打包好的成品，可直接点击导出；确认安装完成后可随时清理释放空间。"
                    )
                }
            }
        }

        startupCleanupTask = Task.detached(priority: .utility) { [weak viewModel = self] in
            guard !Task.isCancelled else { return }
            TempWorkspaceManager.cleanupTransientJunk(
                excludingActiveSessionDir: excludedSession,
                excludingInboxFile: excludedInbox
            )
            let bytes = TempWorkspaceManager.calculateTotalCacheBytes()
            await MainActor.run { [weak viewModel] in
                viewModel?.cachedStorageBytes = bytes
                viewModel?.startupCleanupTask = nil
            }
        }
        verifyBuiltInKitInBackground()
    }

    func reloadCustomProfiles() {
        customProfiles = CustomProfileStore.loadAll()
    }

    func openProfileManager() {
        profileFeedbackMessage = nil
        profileFeedbackIsError = false
        reloadCustomProfiles()
        isShowingProfileManager = true
    }

    func importCustomProfileFromFiles() {
        profileFeedbackMessage = nil
        profileFeedbackIsError = false
        documentPickerPresenter.presentProfileImporter(
            onPick: { [weak self] url in
                self?.handlePickedCustomProfile(url: url)
            },
            onCancel: {},
            onPresentationFailure: { [weak self] reason in
                self?.profileFeedbackMessage = reason
                self?.profileFeedbackIsError = true
            }
        )
    }

    private func handlePickedCustomProfile(url: URL) {
        do {
            let imported = try CustomProfileStore.importProfile(from: url)
            reloadCustomProfiles()
            profileFeedbackMessage = "已导入「\(imported.name)」（\(imported.version) / build \(imported.build)）"
            profileFeedbackIsError = false
        } catch {
            profileFeedbackMessage = error.localizedDescription
            profileFeedbackIsError = true
        }
    }

    func deleteCustomProfile(_ profile: RuntimeOffsetProfile) {
        do {
            try CustomProfileStore.delete(profileID: profile.id)
            reloadCustomProfiles()
            profileFeedbackMessage = "已删除配置「\(profile.name)」"
            profileFeedbackIsError = false
        } catch {
            profileFeedbackMessage = "删除失败：\(error.localizedDescription)"
            profileFeedbackIsError = true
        }
    }

    /// Exports an auto-resolved or self-checked `RuntimeOffsetProfile` as a shareable `.json` file.
    func exportRuntimeProfileJSON(_ profile: RuntimeOffsetProfile, onNotice: ((String, Bool) -> Void)? = nil) {
        let tempFileURL: URL
        do {
            tempFileURL = try TempWorkspaceManager.writeTemporaryProfileExportJSON(for: profile)
        } catch {
            let msg = "生成配置 JSON 失败：\(error.localizedDescription)"
            profileFeedbackMessage = msg
            profileFeedbackIsError = true
            onNotice?(msg, true)
            return
        }
        let tempDir = tempFileURL.deletingLastPathComponent()
        documentPickerPresenter.presentExporter(fileURL: tempFileURL) { [weak self] exportResult in
            TempWorkspaceManager.removeSessionDirectory(tempDir)
            switch exportResult {
            case .saved(let urls):
                let savedName = urls.first?.lastPathComponent ?? tempFileURL.lastPathComponent
                let msg = "已导出适配配置：\(savedName)"
                self?.profileFeedbackMessage = msg
                self?.profileFeedbackIsError = false
                onNotice?(msg, false)
            case .cancelled:
                break
            case .failed(let reason):
                let msg = "导出适配配置失败：\(reason)"
                self?.profileFeedbackMessage = msg
                self?.profileFeedbackIsError = true
                onNotice?(msg, true)
            }
        }
    }

    func copyRuntimeProfileJSON(_ profile: RuntimeOffsetProfile) -> Bool {
        guard let json = try? profile.encodeToPrettyJSONString() else {
            return false
        }
        UIPasteboard.general.string = json
        return true
    }

    func runAutoResolverSelfCheckFromFiles() {
        guard !isRunningSelfCheck else { return }
        selfCheckError = nil
        selfCheckStatus = nil
        documentPickerPresenter.presentImporter(
            onPick: { [weak self] url in
                self?.executeAutoResolverSelfCheck(sourceURL: url)
            },
            onCancel: {},
            onPresentationFailure: { [weak self] reason in
                self?.selfCheckError = reason
            }
        )
    }

    func cancelAutoResolverSelfCheck() {
        selfCheckTask?.cancel()
    }

    private func executeAutoResolverSelfCheck(sourceURL: URL) {
        selfCheckTask?.cancel()
        isRunningSelfCheck = true
        selfCheckError = nil
        selfCheckResult = nil
        selfCheckStatus = "正在准备读取 IPA…"
        let fileName = sourceURL.lastPathComponent

        UIApplication.shared.isIdleTimerDisabled = true
        endSelfCheckBackgroundTask()
        selfCheckBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "ArknightsSelfCheck") { [weak self] in
            Task { @MainActor [weak self] in
                self?.selfCheckTask?.cancel()
                self?.endSelfCheckBackgroundTask()
            }
        }

        let pendingStartupCleanup = startupCleanupTask
        startupCleanupTask?.cancel()
        selfCheckTask = Task.detached(priority: .userInitiated) { [weak viewModel = self] in
            await pendingStartupCleanup?.value
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
                TempWorkspaceManager.cleanupImportedInboxCopyIfNeeded(sourceURL)
                Task { @MainActor [weak viewModel] in
                    guard let viewModel else { return }
                    viewModel.isRunningSelfCheck = false
                    if !viewModel.state.isProcessing {
                        UIApplication.shared.isIdleTimerDisabled = false
                    }
                    viewModel.endSelfCheckBackgroundTask()
                    viewModel.refreshCacheSize()
                }
            }

            do {
                let engine = try IPAPatcherEngine.builtInDefault()
                let output = try Self.withCoordinatedRead(at: sourceURL) { readableURL in
                    try engine.selfCheckAutoResolver(ipaURL: readableURL) { [weak viewModel] status in
                        Task { @MainActor [weak viewModel] in
                            viewModel?.selfCheckStatus = status
                        }
                    }
                }
                let result = AutoResolverSelfCheckResult(
                    fileName: fileName,
                    hostVersion: output.host.version,
                    hostBuild: output.host.build,
                    metadataVersion: output.report.metadataVersion,
                    durationSeconds: output.report.durationSeconds,
                    isConfirmedCompatible: output.report.isConfirmedCompatible,
                    abiChecksSummary: output.report.abiChecksSummary,
                    unverifiedReasons: output.report.unverifiedReasons,
                    comparisons: output.comparisons,
                    resolvedProfile: output.report.profile
                )
                await MainActor.run { [weak viewModel] in
                    viewModel?.selfCheckResult = result
                    viewModel?.selfCheckStatus = nil
                    viewModel?.selfCheckError = nil
                }
            } catch is CancellationError {
                await MainActor.run { [weak viewModel] in
                    viewModel?.selfCheckResult = nil
                    viewModel?.selfCheckStatus = nil
                    viewModel?.selfCheckError = "已取消自动定位验算。"
                }
            } catch {
                await MainActor.run { [weak viewModel] in
                    viewModel?.selfCheckResult = nil
                    viewModel?.selfCheckStatus = nil
                    viewModel?.selfCheckError = error.localizedDescription
                }
            }
        }
    }

    func refreshCacheSize() {
        Task.detached(priority: .utility) { [weak viewModel = self] in
            let bytes = TempWorkspaceManager.calculateTotalCacheBytes()
            await MainActor.run { [weak viewModel] in
                viewModel?.cachedStorageBytes = bytes
            }
        }
    }

    func verifyBuiltInKitInBackground() {
        guard !isCheckingBuiltInKit else { return }
        isCheckingBuiltInKit = true
        builtInKitCheckError = nil

        Task.detached(priority: .utility) { [weak viewModel = self] in
            do {
                let engine = try IPAPatcherEngine.builtInDefault()
                let verified = try engine.verifyConfiguredKits()
                await MainActor.run { [weak viewModel] in
                    viewModel?.builtInKit = verified.first
                    viewModel?.builtInKitCheckError = nil
                    viewModel?.isCheckingBuiltInKit = false
                }
            } catch {
                await MainActor.run { [weak viewModel] in
                    viewModel?.builtInKit = nil
                    viewModel?.builtInKitCheckError = error.localizedDescription
                    viewModel?.isCheckingBuiltInKit = false
                }
            }
        }
    }

    func openFileImporter() {
        guard !state.isProcessing else { return }
        storageNotice = nil
        incomingBusyNotice = nil
        documentPickerPresenter.presentImporter(
            onPick: { [weak self] url in
                self?.startProcessing(sourceURL: url)
            },
            onCancel: {},
            onPresentationFailure: { [weak self] reason in
                self?.state = .failed(
                    fileName: "未选择文件",
                    hostProfile: nil,
                    title: "无法打开文件选择器",
                    message: reason,
                    technicalDetail: reason
                )
            }
        )
    }

    func handleIncomingOpenURL(_ url: URL) {
        if state.isProcessing || isRunningSelfCheck {
            TempWorkspaceManager.cleanupImportedInboxCopyIfNeeded(url)
            incomingBusyNotice = "当前正在处理任务，已忽略外部打开的「\(url.lastPathComponent)」，请等待完成后重试。"
            refreshCacheSize()
            return
        }
        incomingBusyNotice = nil
        let ext = url.pathExtension.lowercased()
        if ext == "json" || ext == "plist" {
            openProfileManager()
            handlePickedCustomProfile(url: url)
            return
        }
        storageNotice = nil
        startProcessing(sourceURL: url)
    }

    func dismissIncomingBusyNotice() {
        incomingBusyNotice = nil
    }

    func startProcessing(sourceURL: URL) {
        activeTask?.cancel()
        TempWorkspaceManager.removeSessionDirectory(currentTransientDirectory)
        currentTransientDirectory = nil
        activeSourceURL = sourceURL
        isShowingProfileManager = false
        storageNotice = nil
        incomingBusyNotice = nil

        let fileName = sourceURL.lastPathComponent
        if sourceURL.pathExtension.lowercased() != "ipa" {
            activeSourceURL = nil
            TempWorkspaceManager.cleanupImportedInboxCopyIfNeeded(sourceURL)
            refreshCacheSize()
            state = .failed(
                fileName: fileName,
                hostProfile: nil,
                title: "请选择 .ipa 安装包",
                message: "你选择的「\(fileName)」不是 .ipa 文件，请重新选择已砸壳的《明日方舟》官服 IPA。",
                technicalDetail: "Unexpected file extension: .\(sourceURL.pathExtension)"
            )
            return
        }

        let optionsSnapshot = currentPatchOptions
        let customProfilesSnapshot = customProfiles

        let initialProgress = PatchProgress(
            stage: .verifyingKit,
            fractionCompleted: 0,
            detailMessage: "正在准备本地打包环境与内置补丁组件…"
        )
        state = .processing(
            fileName: fileName,
            fileSize: nil,
            hostProfile: nil,
            progress: initialProgress
        )
        UIApplication.shared.isIdleTimerDisabled = true
        endActiveBackgroundTask()
        activeBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "ArknightsIPAPatch") { [weak self] in
            Task { @MainActor [weak self] in
                self?.activeTask?.cancel()
                self?.endActiveBackgroundTask()
            }
        }

        let throttler = ProgressThrottler()
        let pendingStartupCleanup = startupCleanupTask
        startupCleanupTask?.cancel()

        activeTask = Task.detached(priority: .userInitiated) { [weak viewModel = self] in
            await pendingStartupCleanup?.value
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            var transientDir: URL?
            var identifiedHost: HostIPAProfile?

            defer {
                if accessed {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
                TempWorkspaceManager.cleanupImportedInboxCopyIfNeeded(sourceURL)
                Task { @MainActor [weak viewModel] in
                    guard let viewModel else { return }
                    viewModel.activeSourceURL = nil
                    if !viewModel.isRunningSelfCheck {
                        UIApplication.shared.isIdleTimerDisabled = false
                    }
                    viewModel.endActiveBackgroundTask()
                    viewModel.refreshCacheSize()
                }
            }

            let publishProgress: @Sendable (PatchProgress, HostIPAProfile?, UInt64?) -> Void = { [weak viewModel] progress, host, fileSize in
                guard throttler.shouldEmit(stage: progress.stage, fraction: progress.fractionCompleted) else {
                    return
                }
                Task { @MainActor [weak viewModel] in
                    guard let viewModel, viewModel.state.isProcessing else { return }
                    viewModel.state = .processing(
                        fileName: fileName,
                        fileSize: fileSize,
                        hostProfile: host,
                        progress: progress
                    )
                }
            }

            enum PipelineOutcome {
                case incompatible(HostIPAProfile, IncompatibilityReport)
                case ready(PendingExportRecord)
            }

            do {
                try Task.checkCancellation()

                let outcome: PipelineOutcome = try Self.withCoordinatedRead(at: sourceURL) { readableSourceURL in
                    guard FileManager.default.isReadableFile(atPath: readableSourceURL.path) else {
                        throw PatchError.fileAccessDenied("无法读取 \(fileName)，请确认文件已下载到本机或具有读取权限。")
                    }

                    let resourceValues = try? readableSourceURL.resourceValues(forKeys: [.fileSizeKey])
                    let initialFileSize: UInt64? = {
                        if let sizeInt = resourceValues?.fileSize, sizeInt > 0 {
                            return UInt64(sizeInt)
                        }
                        return nil
                    }()

                    // 0. Verify & load built-in carrier kit ONCE for this entire patch run.
                    let engine = try IPAPatcherEngine.builtInDefault()
                    let loadedKits = try engine.loadAndVerifyConfiguredKits { progress in
                        publishProgress(progress, nil, initialFileSize)
                    }
                    let verifiedKits = loadedKits.map(\.verifiedKit)
                    if let firstKit = verifiedKits.first {
                        Task { @MainActor [weak viewModel] in
                            viewModel?.builtInKit = firstKit
                            viewModel?.builtInKitCheckError = nil
                        }
                    }

                    // Open a single read-only session so `UnityFramework` is decompressed at most once across all stages.
                    let inputSession = try engine.openInputSession(at: readableSourceURL)

                    // 1. Entry 1: Host Identification.
                    let host = try engine.inspectHost(session: inputSession, options: .default) { progress in
                        publishProgress(progress, nil, initialFileSize)
                    }
                    identifiedHost = host

                    publishProgress(
                        PatchProgress(
                            stage: .matchingCompatibility,
                            fractionCompleted: 0.1,
                            detailMessage: "已识别 \(host.displayName) \(host.version) (Build \(host.build))，正在匹配补丁方案…"
                        ),
                        host,
                        host.sourceFileSize
                    )

                    // 2. Entry 2: 3-Tier Compatibility Matching (Manual > Built-in > Confirmed Auto IL2CPP).
                    let matchResult = try engine.matchCompatibility(
                        for: host,
                        verifiedKits: verifiedKits,
                        customProfiles: customProfilesSnapshot,
                        options: optionsSnapshot,
                        sourceIPAURL: readableSourceURL,
                        inputSession: inputSession
                    ) { progress in
                        publishProgress(progress, host, host.sourceFileSize)
                    }

                    switch matchResult {
                    case .incompatible(let report):
                        inputSession.releaseUnityCache()
                        return .incompatible(host, report)

                    case .matched(let config):
                        try Self.ensureSufficientDiskSpace(forSourceBytes: host.sourceFileSize)

                        let createdDir = try TempWorkspaceManager.createSessionDirectory()
                        transientDir = createdDir
                        Task { @MainActor [weak viewModel] in
                            viewModel?.currentTransientDirectory = createdDir
                        }

                        // 3. Entry 3: Unified Preflight, Streaming Repackaging, Output Verification (reusing verified kit).
                        let matchedPreloaded = loadedKits.first { $0.verifiedKit.profile == config.profile }
                        let executionResult = try engine.applyPatch(
                            configuration: config,
                            sourceIPAURL: readableSourceURL,
                            workingDirectory: createdDir,
                            options: optionsSnapshot,
                            inputSession: inputSession,
                            preloadedKit: matchedPreloaded,
                            overwriteExistingOutput: false
                        ) { progress in
                            publishProgress(progress, host, host.sourceFileSize)
                        }

                        try Task.checkCancellation()

                        let pendingRecord = try TempWorkspaceManager.promoteVerifiedExport(from: executionResult)
                        TempWorkspaceManager.removeSessionDirectory(createdDir)
                        transientDir = nil
                        return .ready(pendingRecord)
                    }
                }

                switch outcome {
                case .incompatible(let host, let report):
                    await MainActor.run { [weak viewModel] in
                        viewModel?.state = .incompatible(fileName: fileName, hostProfile: host, report: report)
                    }
                case .ready(let pendingRecord):
                    await MainActor.run { [weak viewModel] in
                        guard let viewModel else { return }
                        viewModel.currentTransientDirectory = nil
                        viewModel.activePendingRecord = pendingRecord
                        viewModel.state = .readyToExport(result: pendingRecord.result, exportNotice: nil)
                    }
                }
            } catch is CancellationError {
                TempWorkspaceManager.removeSessionDirectory(transientDir)
                await MainActor.run { [weak viewModel] in
                    guard let viewModel else { return }
                    viewModel.currentTransientDirectory = nil
                    viewModel.state = .cancelled(fileName: fileName)
                }
            } catch let patchError as PatchError {
                TempWorkspaceManager.removeSessionDirectory(transientDir)
                let hostSnapshot = identifiedHost
                await MainActor.run { [weak viewModel] in
                    guard let viewModel else { return }
                    viewModel.currentTransientDirectory = nil
                    if case .incompatibleHost(let report) = patchError, let hostSnapshot {
                        viewModel.state = .incompatible(fileName: fileName, hostProfile: hostSnapshot, report: report)
                    } else {
                        viewModel.state = .failed(
                            fileName: fileName,
                            hostProfile: hostSnapshot,
                            title: patchError.userTitle,
                            message: patchError.localizedDescription,
                            technicalDetail: String(describing: patchError)
                        )
                    }
                }
            } catch {
                TempWorkspaceManager.removeSessionDirectory(transientDir)
                let hostSnapshot = identifiedHost
                await MainActor.run { [weak viewModel] in
                    guard let viewModel else { return }
                    viewModel.currentTransientDirectory = nil
                    viewModel.state = .failed(
                        fileName: fileName,
                        hostProfile: hostSnapshot,
                        title: "处理过程中发生错误",
                        message: error.localizedDescription,
                        technicalDetail: String(describing: error)
                    )
                }
            }
        }
    }

    func cancelProcessing() {
        activeTask?.cancel()
    }

    func presentExporter() {
        guard let result = state.exportableResult else { return }
        documentPickerPresenter.presentExporter(fileURL: result.outputURL) { [weak self] exportResult in
            self?.handleExportResult(exportResult)
        }
    }

    func handleExportResult(_ exportResult: SystemExportResult) {
        guard let currentResult = state.exportableResult else { return }

        switch exportResult {
        case .saved(let urls):
            let savedName = urls.first?.lastPathComponent ?? currentResult.suggestedExportFilename
            if let existing = activePendingRecord {
                activePendingRecord = TempWorkspaceManager.markPendingExportSaved(existing, exportedFileName: savedName)
            }
            state = .exported(result: currentResult, exportedFileName: savedName)
        case .cancelled:
            state = .readyToExport(
                result: currentResult,
                exportNotice: "已取消本次导出，打包好的成品仍保留在本机（切出去清理空间也不会丢失），随时可以再次导出。"
            )
        case .failed(let message):
            state = .readyToExport(
                result: currentResult,
                exportNotice: "导出未完成：\(message)。成品已保留，清理存储空间后可再次尝试导出。"
            )
        }
    }

    func deleteLocalOutputAndFreeSpace() {
        guard !state.isProcessing, !isClearingCache else { return }
        activeTask?.cancel()
        activeTask = nil
        currentTransientDirectory = nil
        activePendingRecord = nil
        isClearingCache = true
        state = .idle

        Task.detached(priority: .userInitiated) { [weak viewModel = self] in
            let outcome = TempWorkspaceManager.deleteAllLocalCache()
            await MainActor.run { [weak viewModel] in
                guard let viewModel else { return }
                viewModel.isClearingCache = false
                viewModel.cachedStorageBytes = outcome.remaining
                if outcome.freed > 0 && outcome.remaining == 0 {
                    let formatted = ByteCountFormatter.string(fromByteCount: Int64(min(outcome.freed, UInt64(Int64.max))), countStyle: .file)
                    viewModel.storageNotice = "已清理暂存成品与缓存，释放 \(formatted)。"
                } else if outcome.remaining > 0 {
                    let remStr = ByteCountFormatter.string(fromByteCount: Int64(min(outcome.remaining, UInt64(Int64.max))), countStyle: .file)
                    viewModel.storageNotice = "部分文件正被占用未能删除，当前仍剩余 \(remStr)。"
                } else {
                    viewModel.storageNotice = "本地暂无缓存文件，当前不占用额外空间。"
                }
            }
        }
    }

    func clearAllLocalCacheManually() {
        guard !state.isProcessing, !isClearingCache else { return }
        activePendingRecord = nil
        isClearingCache = true
        if state.exportableResult != nil {
            state = .idle
        }

        Task.detached(priority: .userInitiated) { [weak viewModel = self] in
            let outcome = TempWorkspaceManager.deleteAllLocalCache()
            await MainActor.run { [weak viewModel] in
                guard let viewModel else { return }
                viewModel.isClearingCache = false
                viewModel.cachedStorageBytes = outcome.remaining
                if outcome.freed > 0 && outcome.remaining == 0 {
                    let formatted = ByteCountFormatter.string(fromByteCount: Int64(min(outcome.freed, UInt64(Int64.max))), countStyle: .file)
                    viewModel.storageNotice = "已清理本地缓存，释放 \(formatted)。"
                } else if outcome.remaining > 0 {
                    let remStr = ByteCountFormatter.string(fromByteCount: Int64(min(outcome.remaining, UInt64(Int64.max))), countStyle: .file)
                    viewModel.storageNotice = "部分文件正被占用未能删除，当前仍剩余 \(remStr)。"
                } else {
                    viewModel.storageNotice = "本地暂无缓存文件，当前不占用额外空间。"
                }
            }
        }
    }

    func returnToHomeKeepingOutput() {
        guard !state.isProcessing else { return }
        state = .idle
        refreshCacheSize()
    }

    func restorePendingExportIfPresent() {
        guard !state.isProcessing, let record = activePendingRecord ?? TempWorkspaceManager.loadPendingExport() else {
            return
        }
        activePendingRecord = record
        if let exportedName = record.exportedFileName {
            state = .exported(result: record.result, exportedFileName: exportedName)
        } else {
            state = .readyToExport(result: record.result, exportNotice: nil)
        }
    }

    private func endActiveBackgroundTask() {
        if activeBackgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(activeBackgroundTaskID)
            activeBackgroundTaskID = .invalid
        }
    }

    private func endSelfCheckBackgroundTask() {
        if selfCheckBackgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(selfCheckBackgroundTaskID)
            selfCheckBackgroundTaskID = .invalid
        }
    }

    /// Runs `body` directly if `url` is locally readable; otherwise holds an `NSFileCoordinator` read scope
    /// for the entire duration of `body` so iCloud/FileProvider downloads stay pinned while reading.
    nonisolated private static func withCoordinatedRead<T>(
        at url: URL,
        body: (URL) throws -> T
    ) throws -> T {
        if FileManager.default.isReadableFile(atPath: url.path) {
            return try body(url)
        }
        var coordError: NSError?
        var innerResult: Result<T, Error>?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordError) { resolvedURL in
            innerResult = Result { try body(resolvedURL) }
        }
        if let coordError {
            throw PatchError.fileAccessDenied(coordError.localizedDescription)
        }
        guard let innerResult else {
            throw PatchError.fileAccessDenied("无法协调读取 \(url.lastPathComponent)，请确认文件已下载到本机。")
        }
        return try innerResult.get()
    }

    nonisolated private static func ensureSufficientDiskSpace(forSourceBytes sourceBytes: UInt64) throws {
        let tempDir = FileManager.default.temporaryDirectory
        let values = try? tempDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available: UInt64?
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            available = UInt64(important)
        } else if let regular = values?.volumeAvailableCapacity, regular > 0 {
            available = UInt64(regular)
        } else {
            available = nil
        }

        guard let availableBytes = available else { return }
        let margin: UInt64 = max(128 * 1024 * 1024, sourceBytes / 10)
        let requiredBytes = sourceBytes &+ margin
        if availableBytes < requiredBytes {
            throw PatchError.insufficientDiskSpace(requiredBytes: requiredBytes, availableBytes: availableBytes)
        }
    }
}

private final class ProgressThrottler: @unchecked Sendable {
    private let lock = NSLock()
    private var lastStage: PatchPipelineStage?
    private var lastEmitTime: TimeInterval = 0

    func shouldEmit(stage: PatchPipelineStage, fraction: Double?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSinceReferenceDate
        let isStageChange = (stage != lastStage)
        let isTerminal = (fraction ?? 0) >= 0.999
        if isStageChange || isTerminal || (now - lastEmitTime) >= 0.06 {
            lastStage = stage
            lastEmitTime = now
            return true
        }
        return false
    }
}
