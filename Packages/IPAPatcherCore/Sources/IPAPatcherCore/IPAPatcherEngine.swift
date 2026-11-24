import Foundation

/// High-level facade exposing the three core entries of `IPAPatcherCore`:
/// 1. `inspectHost(at:)` / `inspectHost(session:)` — Host IPA identification
/// 2. `matchCompatibility(for:...)` — 3-tier compatibility matching (manual > built-in > confirmed auto IL2CPP)
/// 3. `applyPatch(configuration:...)` — Unified preflight, streaming repackage & output verification
public struct IPAPatcherEngine: Sendable {
    public let profiles: [TrustedPatchProfile]
    public let inspector: HostInspector
    public let kitVerifier: KitIntegrityVerifier
    public let matcher: CompatibilityMatcher
    public let applicator: PatchApplicator

    public init(
        profiles: [TrustedPatchProfile],
        inspector: HostInspector = HostInspector(),
        kitVerifier: KitIntegrityVerifier = KitIntegrityVerifier(),
        matcher: CompatibilityMatcher = CompatibilityMatcher(),
        applicator: PatchApplicator = PatchApplicator()
    ) {
        self.profiles = profiles
        self.inspector = inspector
        self.kitVerifier = kitVerifier
        self.matcher = matcher
        self.applicator = applicator
    }

    public static func builtInDefault() throws -> IPAPatcherEngine {
        let profiles = try BuiltInKitRepository.allBuiltInProfiles()
        return IPAPatcherEngine(profiles: profiles)
    }

    /// Opens a shared read-only input session so `UnityFramework` is decompressed at most once across all pipeline stages.
    public func openInputSession(at ipaURL: URL) throws -> PatchInputSession {
        try PatchInputSession(ipaURL: ipaURL)
    }

    /// Verifies all configured patch kits (manifest SHA-256 + payload.zip SHA-256 + all entry hashes).
    public func verifyConfiguredKits(
        onProgress: (@Sendable (PatchProgress) -> Void)? = nil
    ) throws -> [VerifiedPatchKit] {
        try Task.checkCancellation()
        onProgress?(
            PatchProgress(
                stage: .verifyingKit,
                fractionCompleted: 0.2,
                detailMessage: "正在检查内置补丁组件完整性…"
            )
        )
        var verified: [VerifiedPatchKit] = []
        for profile in profiles {
            try Task.checkCancellation()
            verified.append(try kitVerifier.verifyKit(profile: profile, verifyPayloadEntries: true))
        }
        onProgress?(
            PatchProgress(
                stage: .verifyingKit,
                fractionCompleted: 1.0,
                detailMessage: "内置补丁组件校验通过"
            )
        )
        return verified
    }

    /// Verifies all configured patch kits AND retains the verified overlay in memory so a subsequent
    /// `applyPatch(..., preloadedKit:)` call avoids decompressing and hashing `payload.zip` a second time.
    public func loadAndVerifyConfiguredKits(
        onProgress: (@Sendable (PatchProgress) -> Void)? = nil
    ) throws -> [LoadedVerifiedKit] {
        try Task.checkCancellation()
        onProgress?(
            PatchProgress(
                stage: .verifyingKit,
                fractionCompleted: 0.2,
                detailMessage: "正在准备并校验内置补丁组件…"
            )
        )
        var loaded: [LoadedVerifiedKit] = []
        for profile in profiles {
            try Task.checkCancellation()
            loaded.append(try kitVerifier.loadAndVerifyOverlay(profile: profile))
        }
        onProgress?(
            PatchProgress(
                stage: .verifyingKit,
                fractionCompleted: 1.0,
                detailMessage: "内置补丁组件已就绪"
            )
        )
        return loaded
    }

    /// Entry 1: Host Identification (standalone URL).
    public func inspectHost(
        at ipaURL: URL,
        options: HostInspectionOptions = .default,
        onProgress: (@Sendable (PatchProgress) -> Void)? = nil
    ) throws -> HostIPAProfile {
        try inspector.inspect(ipaURL: ipaURL, options: options, onProgress: onProgress)
    }

    /// Entry 1: Host Identification (shared read-only session).
    public func inspectHost(
        session: PatchInputSession,
        options: HostInspectionOptions = .default,
        onProgress: (@Sendable (PatchProgress) -> Void)? = nil
    ) throws -> HostIPAProfile {
        try inspector.inspect(session: session, options: options, onProgress: onProgress)
    }

    /// Entry 2: 3-Tier Compatibility Matching.
    public func matchCompatibility(
        for host: HostIPAProfile,
        verifiedKits: [VerifiedPatchKit],
        customProfiles: [RuntimeOffsetProfile] = [],
        options: PatchOptions = .default,
        sourceIPAURL: URL? = nil,
        inputSession: PatchInputSession? = nil,
        onProgress: (@Sendable (PatchProgress) -> Void)? = nil
    ) throws -> CompatibilityMatchResult {
        try Task.checkCancellation()
        onProgress?(
            PatchProgress(
                stage: .matchingCompatibility,
                fractionCompleted: 0.25,
                detailMessage: "正在匹配最合适的补丁方案…"
            )
        )
        let result = try matcher.match(
            host: host,
            against: verifiedKits,
            customProfiles: customProfiles,
            options: options,
            sourceIPAURL: sourceIPAURL,
            inputSession: inputSession
        ) { statusText in
            onProgress?(
                PatchProgress(
                    stage: .matchingCompatibility,
                    fractionCompleted: 0.65,
                    detailMessage: statusText
                )
            )
        }
        onProgress?(
            PatchProgress(
                stage: .matchingCompatibility,
                fractionCompleted: 1.0,
                detailMessage: {
                    switch result {
                    case .matched(let config):
                        return "匹配成功（\(config.adaptationMode.badgeTitle)）：\(config.effectiveRevision)"
                    case .incompatible:
                        return "未匹配到确认兼容的配置"
                    }
                }()
            )
        )
        return result
    }

    /// Entry 3: Verification & Application.
    public func applyPatch(
        configuration: MatchedPatchConfiguration,
        sourceIPAURL: URL,
        workingDirectory: URL,
        options: PatchOptions = .default,
        inputSession: PatchInputSession? = nil,
        preloadedKit: LoadedVerifiedKit? = nil,
        overwriteExistingOutput: Bool = false,
        onProgress: (@Sendable (PatchProgress) -> Void)? = nil
    ) throws -> PatchExecutionResult {
        try applicator.apply(
            configuration: configuration,
            sourceIPAURL: sourceIPAURL,
            workingDirectory: workingDirectory,
            options: options,
            inputSession: inputSession,
            preloadedKit: preloadedKit,
            overwriteExistingOutput: overwriteExistingOutput,
            onProgress: onProgress
        )
    }

    /// Runs `IL2CPPAutoResolver` blind against a verified 2.7.91 / build 76 baseline IPA
    /// and compares all 14 offsets against the built-in 2.7.91/76 ground truth.
    /// Confirms the input truly IS the 2.7.91 / build 76 baseline before computing 14-offset parity.
    public func selfCheckAutoResolver(
        ipaURL: URL,
        onStatus: (@Sendable (String) -> Void)? = nil
    ) throws -> (host: HostIPAProfile, report: IL2CPPAutoResolutionReport, comparisons: [IL2CPPOffsetComparison]) {
        let verifiedKits = try verifyConfiguredKits()
        guard let baselineKit = verifiedKits.first else {
            throw PatchError.missingBuiltInKit("缺少内置 2.7.91 基准包")
        }

        onStatus?("正在识别 IPA 并核对是否属于 2.7.91 / build 76 基准包…")
        let session = try openInputSession(at: ipaURL)
        let host = try inspector.inspect(session: session, options: .default)

        let baselineMismatches = matcher.evaluateMismatches(host: host, manifest: baselineKit.manifest)
        if !baselineMismatches.isEmpty {
            let reason = baselineMismatches.first.map { "\($0.fieldLabel)：期望 \($0.expected)，实际 \($0.actual)" }
                ?? "版本或二进制 UUID 与基准不一致"
            throw PatchError.autoResolutionFailed(
                "所选 IPA 不是 \(baselineKit.manifest.version) (build \(baselineKit.manifest.build)) 原版基准包，无法与 2.7.91 真值逐项对照（\(reason)）"
            )
        }

        let resolver = IL2CPPAutoResolver()
        let report = try resolver.resolve(session: session, hostProfile: host, onProgress: onStatus)

        let resolvedOffsets: IL2CPPOffsetSet
        if let profile = report.profile {
            resolvedOffsets = profile.il2cppOffsets
        } else {
            let byKey = Dictionary(uniqueKeysWithValues: report.items.map { ($0.key, $0.rva) })
            resolvedOffsets = IL2CPPOffsetSet(
                sdkInterfaceClassSlot: byKey["sdkInterfaceClassSlot"] ?? 0,
                sdkExternalToolsClassSlot: byKey["sdkExternalToolsClassSlot"] ?? 0,
                sdkMetaClassSlot: byKey["sdkMetaClassSlot"] ?? 0,
                networkerTypeSlot: byKey["networkerTypeSlot"] ?? 0,
                networkerExpectedClass: byKey["networkerExpectedClass"] ?? 0,
                gameFlowClassSlot: byKey["gameFlowClassSlot"] ?? 0,
                getNetworkConfigFn: byKey["getNetworkConfigFn"] ?? 0,
                overrideNetworkOptionsFn: byKey["overrideNetworkOptionsFn"] ?? 0,
                createStringFn: byKey["createStringFn"] ?? 0,
                internalSDKMetaFn: byKey["internalSDKMetaFn"] ?? 0,
                sdkMetaCtorFn: byKey["sdkMetaCtorFn"] ?? 0,
                clearAuthStatusFn: byKey["clearAuthStatusFn"] ?? 0,
                clearLoginStatusFn: byKey["clearLoginStatusFn"] ?? 0,
                getCurrentSceneFn: byKey["getCurrentSceneFn"] ?? 0
            )
        }

        let comparisons = IL2CPPAutoResolver.compare(resolved: resolvedOffsets, against: .builtIn2791)
        return (host, report, comparisons)
    }
}
