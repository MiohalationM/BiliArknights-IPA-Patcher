import Foundation
import IPAPatcherCore
import Observation
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
@Observable
final class PatchPipelineViewModel {
    private static let iconPrefKey = "ArknightsPatcher.applyCustomBiliIcons"
    private static let autoAdaptPrefKey = "ArknightsPatcher.enableAutoAdaptation"

    var state: PatchSessionState = .idle
    var isShowingProfileManager: Bool = false

    // User preferences (persisted in UserDefaults)
    var applyCustomBiliIcons: Bool {
        didSet { UserDefaults.standard.set(applyCustomBiliIcons, forKey: Self.iconPrefKey) }
    }
    var enableAutoAdaptation: Bool {
        didSet { UserDefaults.standard.set(enableAutoAdaptation, forKey: Self.autoAdaptPrefKey) }
    }

    var currentPatchOptions: PatchOptions {
        PatchOptions(
            applyCustomBiliIcons: applyCustomBiliIcons,
            enableAutoAdaptation: enableAutoAdaptation
        )
    }

    // Built-in base kit state
    private(set) var builtInKit: VerifiedPatchKit?
    private(set) var builtInKitCheckError: String?
    private(set) var isCheckingBuiltInKit: Bool = false

    // Imported manual profiles state
    private(set) var customProfiles: [RuntimeOffsetProfile] = []
    private(set) var profileFeedbackMessage: String?
    private(set) var profileFeedbackIsError: Bool = false

    // On-device 2.7.91 auto-resolver self-check state
    private(set) var isRunningSelfCheck: Bool = false
    private(set) var selfCheckStatus: String?
    private(set) var selfCheckError: String?
    private(set) var selfCheckResult: AutoResolverSelfCheckResult?

    // Local cache state
    private(set) var cachedStorageBytes: UInt64 = 0
    private(set) var storageNotice: String?

    @ObservationIgnored
    private let documentPickerPresenter = SystemDocumentPickerPresenter()
    @ObservationIgnored
    private var activeTask: Task<Void, Never>?
    @ObservationIgnored
    private var selfCheckTask: Task<Void, Never>?
    @ObservationIgnored
    private var currentTransientDirectory: URL?
    @ObservationIgnored
    private var activePendingRecord: PendingExportRecord?

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

    func performStartupSetup() {
        TempWorkspaceManager.cleanupTransientJunk()
        reloadCustomProfiles()
        if let restored = TempWorkspaceManager.loadPendingExport() {
            activePendingRecord = restored
            if let exportedName = restored.exportedFileName {
                state = .exported(result: restored.result, exportedFileName: exportedName)
            } else {
                state = .readyToExport(
                    result: restored.result,
                    exportNotice: "已恢复上次复核通过的成品，可直接继续导出，或点击下方按钮手动删除释放空间。"
                )
            }
        }
        refreshCacheSize()
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

    private func executeAutoResolverSelfCheck(sourceURL: URL) {
        selfCheckTask?.cancel()
        isRunningSelfCheck = true
        selfCheckError = nil
        selfCheckResult = nil
        selfCheckStatus = "正在准备读取 IPA…"
        let fileName = sourceURL.lastPathComponent

        selfCheckTask = Task.detached(priority: .userInitiated) { [weak viewModel = self] in
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
                TempWorkspaceManager.cleanupImportedInboxCopyIfNeeded(sourceURL)
                Task { @MainActor [weak viewModel] in
                    viewModel?.isRunningSelfCheck = false
                    viewModel?.refreshCacheSize()
                }
            }

            do {
                let engine = try IPAPatcherEngine.builtInDefault()
                let output = try engine.selfCheckAutoResolver(ipaURL: sourceURL) { [weak viewModel] status in
                    Task { @MainActor [weak viewModel] in
                        viewModel?.selfCheckStatus = status
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
        guard !state.isProcessing else { return }
        let ext = url.pathExtension.lowercased()
        if ext == "json" || ext == "plist" {
            openProfileManager()
            handlePickedCustomProfile(url: url)
            return
        }
        storageNotice = nil
        startProcessing(sourceURL: url)
    }

    func startProcessing(sourceURL: URL) {
        activeTask?.cancel()
        TempWorkspaceManager.removeSessionDirectory(currentTransientDirectory)
        currentTransientDirectory = nil
        isShowingProfileManager = false
        storageNotice = nil

        let fileName = sourceURL.lastPathComponent
        if sourceURL.pathExtension.lowercased() != "ipa" {
            TempWorkspaceManager.cleanupImportedInboxCopyIfNeeded(sourceURL)
            refreshCacheSize()
            state = .failed(
                fileName: fileName,
                hostProfile: nil,
                title: "请选择 .ipa 文件",
                message: "所选文件「\(fileName)」不是 .ipa 安装包，请重新选择已解密的游戏 IPA。",
                technicalDetail: "Unexpected file extension: .\(sourceURL.pathExtension)"
            )
            return
        }

        let optionsSnapshot = currentPatchOptions
        let customProfilesSnapshot = customProfiles

        let initialProgress = PatchProgress(
            stage: .verifyingKit,
            fractionCompleted: 0,
            detailMessage: "正在准备本地处理环境并校验内置底座…"
        )
        state = .processing(
            fileName: fileName,
            fileSize: nil,
            hostProfile: nil,
            progress: initialProgress
        )
        UIApplication.shared.isIdleTimerDisabled = true

        let throttler = ProgressThrottler()

        activeTask = Task.detached(priority: .userInitiated) { [weak viewModel = self] in
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            var transientDir: URL?
            var identifiedHost: HostIPAProfile?

            defer {
                if accessed {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
                TempWorkspaceManager.cleanupImportedInboxCopyIfNeeded(sourceURL)
                Task { @MainActor [weak viewModel] in
                    UIApplication.shared.isIdleTimerDisabled = false
                    viewModel?.refreshCacheSize()
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

            do {
                try Task.checkCancellation()

                var readableSourceURL = sourceURL
                if !FileManager.default.isReadableFile(atPath: sourceURL.path) {
                    var coordError: NSError?
                    var resolvedURL: URL?
                    let coordinator = NSFileCoordinator()
                    coordinator.coordinate(readingItemAt: sourceURL, options: .withoutChanges, error: &coordError) { url in
                        resolvedURL = url
                    }
                    if let coordError {
                        throw PatchError.fileAccessDenied(coordError.localizedDescription)
                    }
                    if let resolvedURL {
                        readableSourceURL = resolvedURL
                    }
                }
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

                // 0. Verify built-in carrier kit before touching the host IPA.
                let engine = try IPAPatcherEngine.builtInDefault()
                let verifiedKits = try engine.verifyConfiguredKits { progress in
                    publishProgress(progress, nil, initialFileSize)
                }
                if let firstKit = verifiedKits.first {
                    await MainActor.run { [weak viewModel] in
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

                await MainActor.run { [weak viewModel] in
                    guard let viewModel, viewModel.state.isProcessing else { return }
                    viewModel.state = .processing(
                        fileName: fileName,
                        fileSize: host.sourceFileSize,
                        hostProfile: host,
                        progress: PatchProgress(
                            stage: .matchingCompatibility,
                            fractionCompleted: 0.1,
                            detailMessage: "已识别 \(host.displayName) \(host.version) (build \(host.build))，正在匹配适配配置…"
                        )
                    )
                }

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
                    await MainActor.run { [weak viewModel] in
                        viewModel?.state = .incompatible(fileName: fileName, hostProfile: host, report: report)
                    }
                    return

                case .matched(let config):
                    try Self.ensureSufficientDiskSpace(forSourceBytes: host.sourceFileSize)

                    let createdDir = try TempWorkspaceManager.createSessionDirectory()
                    transientDir = createdDir
                    await MainActor.run { [weak viewModel] in
                        viewModel?.currentTransientDirectory = createdDir
                    }

                    // 3. Entry 3: Unified Preflight, Streaming Repackaging, Output Verification.
                    let executionResult = try engine.applyPatch(
                        configuration: config,
                        sourceIPAURL: readableSourceURL,
                        workingDirectory: createdDir,
                        options: optionsSnapshot,
                        inputSession: inputSession,
                        overwriteExistingOutput: false
                    ) { progress in
                        publishProgress(progress, host, host.sourceFileSize)
                    }

                    try Task.checkCancellation()

                    let pendingRecord = try TempWorkspaceManager.promoteVerifiedExport(from: executionResult)
                    TempWorkspaceManager.removeSessionDirectory(createdDir)
                    transientDir = nil

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
                exportNotice: "已取消系统导出，成品仍保留在本地暂存区（切出去清理空间也不会被自动删掉），可随时再次导出或手动删除。"
            )
        case .failed(let message):
            state = .readyToExport(
                result: currentResult,
                exportNotice: "导出未完成：\(message)。成品已保留，清理空间后可再次尝试导出。"
            )
        }
    }

    func deleteLocalOutputAndFreeSpace() {
        guard !state.isProcessing else { return }
        activeTask?.cancel()
        activeTask = nil
        currentTransientDirectory = nil
        activePendingRecord = nil

        let freed = TempWorkspaceManager.deleteAllLocalCache()
        cachedStorageBytes = 0
        if freed > 0 {
            let formatted = ByteCountFormatter.string(fromByteCount: Int64(min(freed, UInt64(Int64.max))), countStyle: .file)
            storageNotice = "已手动删除本地成品与全部缓存，释放 \(formatted)。"
        } else {
            storageNotice = "本地缓存已清空，当前占用 0 B。"
        }
        state = .idle
    }

    func clearAllLocalCacheManually() {
        guard !state.isProcessing else { return }
        let freed = TempWorkspaceManager.deleteAllLocalCache()
        activePendingRecord = nil
        cachedStorageBytes = 0
        if freed > 0 {
            let formatted = ByteCountFormatter.string(fromByteCount: Int64(min(freed, UInt64(Int64.max))), countStyle: .file)
            storageNotice = "已清理本地缓存，释放 \(formatted)。"
        } else {
            storageNotice = "本地暂无残留缓存，当前占用 0 B。"
        }
        if state.exportableResult != nil {
            state = .idle
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

    var hasPendingExport: Bool {
        activePendingRecord != nil
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
