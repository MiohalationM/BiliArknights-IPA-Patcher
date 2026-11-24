import Foundation

public struct CompatibilityMismatch: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case encryptedBinary
        case bundleID
        case version
        case build
        case appRoot
        case missingBinary
        case binaryArchitecture
        case binaryUUID
        case binaryTextDigest
        case autoResolution
    }

    public let id: String
    public let kind: Kind
    public let fieldLabel: String
    public let expected: String
    public let actual: String
    public let detail: String

    public init(
        kind: Kind,
        fieldLabel: String,
        expected: String,
        actual: String,
        detail: String
    ) {
        self.id = "\(kind.rawValue):\(fieldLabel):\(expected):\(actual):\(detail)"
        self.kind = kind
        self.fieldLabel = fieldLabel
        self.expected = expected
        self.actual = actual
        self.detail = detail
    }
}

public struct IncompatibilityReport: Sendable, Hashable {
    public let actualBundleID: String
    public let actualVersion: String
    public let actualBuild: String
    public let actualAppRoot: String
    public let isEncrypted: Bool
    public let targetRevision: String
    public let targetVersion: String
    public let targetBuild: String
    public let autoAdaptationAttempted: Bool
    public let autoAdaptationFailureReason: String?
    public let mismatches: [CompatibilityMismatch]

    public var summaryText: String {
        if isEncrypted {
            return "检测到未砸壳（已加密）IPA（版本 \(actualVersion) / Build \(actualBuild)），请导入已砸壳的官服 IPA。"
        }
        if let autoReason = autoAdaptationFailureReason {
            return "当前游戏版本为 \(actualVersion)（Build \(actualBuild)），未匹配到内置版本或已导入配置，且自动适配未通过：\(autoReason)"
        }
        if autoAdaptationAttempted {
            return "当前游戏版本为 \(actualVersion)（Build \(actualBuild)），暂未匹配到适配配置，你可以导入新版手工配置后再试。"
        }
        return "当前游戏版本为 \(actualVersion)（Build \(actualBuild)），与内置支持版本 \(targetVersion)（Build \(targetBuild)）不一致（共 \(mismatches.count) 项）。"
    }

    public init(
        actualBundleID: String,
        actualVersion: String,
        actualBuild: String,
        actualAppRoot: String,
        isEncrypted: Bool,
        targetRevision: String,
        targetVersion: String,
        targetBuild: String,
        autoAdaptationAttempted: Bool = false,
        autoAdaptationFailureReason: String? = nil,
        mismatches: [CompatibilityMismatch]
    ) {
        self.actualBundleID = actualBundleID
        self.actualVersion = actualVersion
        self.actualBuild = actualBuild
        self.actualAppRoot = actualAppRoot
        self.isEncrypted = isEncrypted
        self.targetRevision = targetRevision
        self.targetVersion = targetVersion
        self.targetBuild = targetBuild
        self.autoAdaptationAttempted = autoAdaptationAttempted
        self.autoAdaptationFailureReason = autoAdaptationFailureReason
        self.mismatches = mismatches
    }
}

public struct MatchedPatchConfiguration: Sendable, Hashable {
    public let hostProfile: HostIPAProfile
    public let verifiedKit: VerifiedPatchKit
    public let adaptationMode: AdaptationMode
    public let runtimeOffsetProfile: RuntimeOffsetProfile?
    public let autoResolutionReport: IL2CPPAutoResolutionReport?

    public var manifest: PatchKitManifest { verifiedKit.manifest }
    public var profile: TrustedPatchProfile { verifiedKit.profile }

    public var effectiveRevision: String {
        runtimeOffsetProfile?.revision ?? verifiedKit.manifest.revision
    }

    public init(
        hostProfile: HostIPAProfile,
        verifiedKit: VerifiedPatchKit,
        adaptationMode: AdaptationMode = .builtInVerified,
        runtimeOffsetProfile: RuntimeOffsetProfile? = nil,
        autoResolutionReport: IL2CPPAutoResolutionReport? = nil
    ) {
        self.hostProfile = hostProfile
        self.verifiedKit = verifiedKit
        self.adaptationMode = adaptationMode
        self.runtimeOffsetProfile = runtimeOffsetProfile
        self.autoResolutionReport = autoResolutionReport
    }
}

public enum CompatibilityMatchResult: Sendable, Hashable {
    case matched(MatchedPatchConfiguration)
    case incompatible(IncompatibilityReport)
}

/// Entry 2: 3-Tier Compatibility Matching.
/// Priority:
/// 1. Manually imported `RuntimeOffsetProfile` matching `bundleID + version + build + UnityFramework UUID`
/// 2. Built-in verified baseline (`2.7.91 / build 76` with full 6-binary UUID verification)
/// 3. Optional on-device single-IPA IL2CPP v27/v29/v31 auto-resolver — ONLY for unknown versions
///    (never papers over a mismatched known baseline version!) and ONLY when `status == .confirmedCompatible`.
public struct CompatibilityMatcher: Sendable {
    public init() {}

    public func match(
        host: HostIPAProfile,
        against verifiedKits: [VerifiedPatchKit],
        customProfiles: [RuntimeOffsetProfile] = [],
        options: PatchOptions = .default,
        sourceIPAURL: URL? = nil,
        inputSession: PatchInputSession? = nil,
        onStatus: (@Sendable (String) -> Void)? = nil
    ) throws -> CompatibilityMatchResult {
        guard let baseKit = verifiedKits.first else {
            throw PatchError.missingBuiltInKit("没有可用的受信补丁配置")
        }

        // Tier 1: Manually imported external adaptation profiles (no App rebuild required for new versions!).
        if !host.isEncrypted && host.appRoot == baseKit.manifest.appRoot {
            let unityPath = host.appRoot + "Frameworks/UnityFramework.framework/UnityFramework"
            let unityIsValidARM64 = isSingleSliceUnencryptedARM64(host.binary(at: unityPath))
            if unityIsValidARM64 {
                for custom in customProfiles where custom.matches(host: host) {
                    try custom.validate()
                    onStatus?("命中手工导入配置：\(custom.name)")
                    return .matched(
                        MatchedPatchConfiguration(
                            hostProfile: host,
                            verifiedKit: baseKit,
                            adaptationMode: .manualCustomProfile,
                            runtimeOffsetProfile: custom
                        )
                    )
                }
            }
        }

        // Tier 2: Built-in verified baseline kits (strict 6-binary UUID parity).
        var reports: [IncompatibilityReport] = []
        for kit in verifiedKits {
            let mismatches = evaluateMismatches(host: host, manifest: kit.manifest)
            if mismatches.isEmpty {
                return .matched(
                    MatchedPatchConfiguration(
                        hostProfile: host,
                        verifiedKit: kit,
                        adaptationMode: .builtInVerified
                    )
                )
            }
            reports.append(
                IncompatibilityReport(
                    actualBundleID: host.bundleID,
                    actualVersion: host.version,
                    actualBuild: host.build,
                    actualAppRoot: host.appRoot,
                    isEncrypted: host.isEncrypted,
                    targetRevision: kit.manifest.revision,
                    targetVersion: kit.manifest.version,
                    targetBuild: kit.manifest.build,
                    mismatches: mismatches
                )
            )
        }

        var best = reports.min(by: { $0.mismatches.count < $1.mismatches.count }) ?? reports[0]

        // Never fall through to Tier 3 auto-adaptation when the IPA claims to be a KNOWN built-in baseline version
        // (e.g. 2.7.91 / build 76) whose binary UUIDs or encryption state failed strict verification!
        let isKnownBuiltInVersion = verifiedKits.contains { kit in
            host.bundleID == kit.manifest.bundleID
                && host.version == kit.manifest.version
                && host.build == kit.manifest.build
        }
        if isKnownBuiltInVersion {
            return .incompatible(best)
        }

        // Tier 3: Optional on-device single-IPA IL2CPP v27/v29/v31 auto-resolver for unknown future Arknights versions.
        let unityPath = host.appRoot + "Frameworks/UnityFramework.framework/UnityFramework"
        if host.il2cppProbe?.detectedInjectedBridge == true {
            let dylibPath = baseKit.manifest.dynamicDylibInjection?.dylibLoadPath ?? "@executable_path/Frameworks/ABLoginBridge.dylib"
            throw PatchError.alreadyInjected(binaryPath: unityPath, dylibPath: dylibPath)
        }
        let hasReadableInput = (inputSession != nil || sourceIPAURL != nil)
        let eligibleForAutoAdapt = options.enableAutoAdaptation
            && hasReadableInput
            && !host.isEncrypted
            && host.bundleID == baseKit.manifest.bundleID
            && host.appRoot == baseKit.manifest.appRoot
            && isSingleSliceUnencryptedARM64(host.binary(at: unityPath))

        if eligibleForAutoAdapt {
            do {
                onStatus?("检测到新版本，正在尝试本机自动分析适配…")
                let resolver = IL2CPPAutoResolver()
                let resolution: IL2CPPAutoResolutionReport
                if let session = inputSession {
                    resolution = try resolver.resolve(session: session, hostProfile: host, onProgress: onStatus)
                } else if let ipaURL = sourceIPAURL {
                    resolution = try resolver.resolve(sourceIPAURL: ipaURL, hostProfile: host, onProgress: onStatus)
                } else {
                    return .incompatible(best)
                }

                if resolution.isConfirmedCompatible, let confirmedProfile = resolution.profile {
                    return .matched(
                        MatchedPatchConfiguration(
                            hostProfile: host,
                            verifiedKit: baseKit,
                            adaptationMode: .autoResolved,
                            runtimeOffsetProfile: confirmedProfile,
                            autoResolutionReport: resolution
                        )
                    )
                }

                // Two-state gate: candidates found, but lacked sufficient ABI / uniqueness proof -> DO NOT allow export.
                let reasons = resolution.unverifiedReasons
                let summaryReason = reasons.first ?? "缺少足够的结构体 ABI 或候选唯一性证据"
                var augmented = best.mismatches
                for reason in reasons.reversed() {
                    augmented.insert(
                        CompatibilityMismatch(
                            kind: .autoResolution,
                            fieldLabel: "自动适配诊断（未确认兼容）",
                            expected: "唯一候选 + 完整字节级 ABI 校验通过",
                            actual: "证据不足，已阻止导出",
                            detail: reason
                        ),
                        at: 0
                    )
                }
                best = IncompatibilityReport(
                    actualBundleID: best.actualBundleID,
                    actualVersion: best.actualVersion,
                    actualBuild: best.actualBuild,
                    actualAppRoot: best.actualAppRoot,
                    isEncrypted: best.isEncrypted,
                    targetRevision: best.targetRevision,
                    targetVersion: best.targetVersion,
                    targetBuild: best.targetBuild,
                    autoAdaptationAttempted: true,
                    autoAdaptationFailureReason: summaryReason,
                    mismatches: augmented
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let patchError as PatchError {
                if case .zipFailure = patchError {
                    throw patchError
                }
                let reason = patchError.localizedDescription
                var augmented = best.mismatches
                augmented.insert(
                    CompatibilityMismatch(
                        kind: .autoResolution,
                        fieldLabel: "自动适配 (IL2CPP)",
                        expected: "唯一候选 + 完整字节级 ABI 校验通过",
                        actual: "未通过",
                        detail: reason
                    ),
                    at: 0
                )
                best = IncompatibilityReport(
                    actualBundleID: best.actualBundleID,
                    actualVersion: best.actualVersion,
                    actualBuild: best.actualBuild,
                    actualAppRoot: best.actualAppRoot,
                    isEncrypted: best.isEncrypted,
                    targetRevision: best.targetRevision,
                    targetVersion: best.targetVersion,
                    targetBuild: best.targetBuild,
                    autoAdaptationAttempted: true,
                    autoAdaptationFailureReason: reason,
                    mismatches: augmented
                )
            } catch {
                let reason = error.localizedDescription
                var augmented = best.mismatches
                augmented.insert(
                    CompatibilityMismatch(
                        kind: .autoResolution,
                        fieldLabel: "自动适配 (IL2CPP)",
                        expected: "唯一候选 + 完整字节级 ABI 校验通过",
                        actual: "未通过",
                        detail: reason
                    ),
                    at: 0
                )
                best = IncompatibilityReport(
                    actualBundleID: best.actualBundleID,
                    actualVersion: best.actualVersion,
                    actualBuild: best.actualBuild,
                    actualAppRoot: best.actualAppRoot,
                    isEncrypted: best.isEncrypted,
                    targetRevision: best.targetRevision,
                    targetVersion: best.targetVersion,
                    targetBuild: best.targetBuild,
                    autoAdaptationAttempted: true,
                    autoAdaptationFailureReason: reason,
                    mismatches: augmented
                )
            }
        }

        return .incompatible(best)
    }

    public func evaluateMismatches(host: HostIPAProfile, manifest: PatchKitManifest) -> [CompatibilityMismatch] {
        var mismatches: [CompatibilityMismatch] = []

        if host.isEncrypted {
            let encryptedNames = host.encryptedBinaryPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
            mismatches.append(
                CompatibilityMismatch(
                    kind: .encryptedBinary,
                    fieldLabel: "砸壳状态",
                    expected: "已砸壳（cryptid = 0）",
                    actual: "未砸壳加密（\(encryptedNames.joined(separator: ", "))）",
                    detail: "本工具不负责砸壳，请导入已砸壳的官服 IPA。"
                )
            )
        }

        if host.bundleID != manifest.bundleID {
            mismatches.append(
                CompatibilityMismatch(
                    kind: .bundleID,
                    fieldLabel: "包名 (Bundle ID)",
                    expected: manifest.bundleID,
                    actual: host.bundleID.isEmpty ? "（空）" : host.bundleID,
                    detail: "当前 IPA 不是目标应用包名。"
                )
            )
        }
        if host.version != manifest.version {
            mismatches.append(
                CompatibilityMismatch(
                    kind: .version,
                    fieldLabel: "版本号",
                    expected: manifest.version,
                    actual: host.version.isEmpty ? "（空）" : host.version,
                    detail: "内置已验证基准版本为 \(manifest.version)。"
                )
            )
        }
        if host.build != manifest.build {
            mismatches.append(
                CompatibilityMismatch(
                    kind: .build,
                    fieldLabel: "构建号 (Build)",
                    expected: manifest.build,
                    actual: host.build.isEmpty ? "（空）" : host.build,
                    detail: "内置已验证基准构建号为 build \(manifest.build)。"
                )
            )
        }
        if host.appRoot != manifest.appRoot {
            mismatches.append(
                CompatibilityMismatch(
                    kind: .appRoot,
                    fieldLabel: "应用目录",
                    expected: manifest.appRoot,
                    actual: host.appRoot,
                    detail: "主 .app 目录名与补丁配置不一致。"
                )
            )
        }

        for path in manifest.hostBinaries.keys.sorted() {
            guard let expected = manifest.hostBinaries[path] else { continue }
            let shortName = URL(fileURLWithPath: path).lastPathComponent

            guard let actualBinary = host.binary(at: path) else {
                mismatches.append(
                    CompatibilityMismatch(
                        kind: .missingBinary,
                        fieldLabel: "必需二进制 · \(shortName)",
                        expected: "存在（arm64 / \(expected.uuid)）",
                        actual: "缺失",
                        detail: "缺少路径 \(path)。"
                    )
                )
                continue
            }

            if actualBinary.slices.count != 1 || actualBinary.slices[0].cpuType != MachOSliceInfo.cpuTypeARM64 {
                mismatches.append(
                    CompatibilityMismatch(
                        kind: .binaryArchitecture,
                        fieldLabel: "架构 · \(shortName)",
                        expected: "单架构 arm64",
                        actual: "\(actualBinary.slices.count) 个切片（\(actualBinary.architectureSummary)）",
                        detail: "\(path) 的 Mach-O 架构与补丁要求不符。"
                    )
                )
                continue
            }

            let slice = actualBinary.slices[0]
            if slice.isEncrypted {
                mismatches.append(
                    CompatibilityMismatch(
                        kind: .encryptedBinary,
                        fieldLabel: "加密状态 · \(shortName)",
                        expected: "cryptid = 0",
                        actual: "cryptid = \(slice.cryptids)",
                        detail: "\(path) 仍处于加密状态。"
                    )
                )
            }
            if slice.uuid?.lowercased() != expected.uuid.lowercased() {
                mismatches.append(
                    CompatibilityMismatch(
                        kind: .binaryUUID,
                        fieldLabel: "UUID · \(shortName)",
                        expected: expected.uuid,
                        actual: slice.uuid ?? "（无 LC_UUID）",
                        detail: "\(path) 的 Mach-O UUID 与内置基准 \(manifest.version)/\(manifest.build) 不同。"
                    )
                )
            }
        }

        return mismatches
    }

    public func evaluateRuntimeProfileMismatches(
        host: HostIPAProfile,
        profile: RuntimeOffsetProfile,
        expectedAppRoot: String
    ) -> [CompatibilityMismatch] {
        var mismatches: [CompatibilityMismatch] = []
        if host.isEncrypted {
            let encryptedNames = host.encryptedBinaryPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
            mismatches.append(
                CompatibilityMismatch(
                    kind: .encryptedBinary,
                    fieldLabel: "砸壳状态",
                    expected: "已砸壳（cryptid = 0）",
                    actual: "未砸壳加密（\(encryptedNames.joined(separator: ", "))）",
                    detail: "本工具不负责砸壳，请导入已砸壳的官服 IPA。"
                )
            )
        }
        if host.bundleID != profile.bundleID {
            mismatches.append(
                CompatibilityMismatch(
                    kind: .bundleID,
                    fieldLabel: "包名 (Bundle ID)",
                    expected: profile.bundleID,
                    actual: host.bundleID,
                    detail: "宿主包名与所选适配配置不一致。"
                )
            )
        }
        if host.version != profile.version {
            mismatches.append(
                CompatibilityMismatch(
                    kind: .version,
                    fieldLabel: "版本号",
                    expected: profile.version,
                    actual: host.version,
                    detail: "宿主版本号与所选适配配置不一致。"
                )
            )
        }
        if host.build != profile.build {
            mismatches.append(
                CompatibilityMismatch(
                    kind: .build,
                    fieldLabel: "构建号 (Build)",
                    expected: profile.build,
                    actual: host.build,
                    detail: "宿主构建号与所选适配配置不一致。"
                )
            )
        }
        if host.appRoot != expectedAppRoot {
            mismatches.append(
                CompatibilityMismatch(
                    kind: .appRoot,
                    fieldLabel: "应用目录",
                    expected: expectedAppRoot,
                    actual: host.appRoot,
                    detail: "主 .app 目录名与补丁底座不一致。"
                )
            )
        }

        let unityPath = expectedAppRoot + "Frameworks/UnityFramework.framework/UnityFramework"
        guard let unityBinary = host.binary(at: unityPath) else {
            mismatches.append(
                CompatibilityMismatch(
                    kind: .missingBinary,
                    fieldLabel: "必需二进制 · UnityFramework",
                    expected: "存在（arm64 / \(profile.unityUUID)）",
                    actual: "缺失",
                    detail: "缺少路径 \(unityPath)。"
                )
            )
            return mismatches
        }
        if !isSingleSliceUnencryptedARM64(unityBinary) {
            mismatches.append(
                CompatibilityMismatch(
                    kind: .binaryArchitecture,
                    fieldLabel: "架构 · UnityFramework",
                    expected: "单架构已砸壳 arm64",
                    actual: "\(unityBinary.slices.count) 个切片（\(unityBinary.architectureSummary)）",
                    detail: "UnityFramework 必须为单架构已砸壳 arm64。"
                )
            )
        } else if unityBinary.primaryUUID?.lowercased() != profile.unityUUID.lowercased() {
            mismatches.append(
                CompatibilityMismatch(
                    kind: .binaryUUID,
                    fieldLabel: "UUID · UnityFramework",
                    expected: profile.unityUUID,
                    actual: unityBinary.primaryUUID ?? "（无 LC_UUID）",
                    detail: "UnityFramework UUID 与适配配置不匹配。"
                )
            )
        }
        return mismatches
    }

    private func isSingleSliceUnencryptedARM64(_ binary: HostBinaryInfo?) -> Bool {
        guard let binary,
              binary.slices.count == 1,
              binary.slices[0].cpuType == MachOSliceInfo.cpuTypeARM64,
              !binary.slices[0].isEncrypted else {
            return false
        }
        return true
    }
}
