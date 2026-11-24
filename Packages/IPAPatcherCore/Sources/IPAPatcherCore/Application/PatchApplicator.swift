import CryptoKit
import Foundation
import Zip64Kit

/// Entry 3: Complete Preflight Verification, Unified Single-Pass Streaming Repackaging, and Output Verification.
public struct PatchApplicator: Sendable {
    public init() {}

    /// Strips original store/signature metadata that should not remain in an unsigned output IPA.
    public static func shouldStripEntry(_ name: String) -> Bool {
        if !name.hasPrefix("Payload/") {
            return true
        }
        let parts = name.split(separator: "/")
        if parts.contains("SC_Info") || parts.contains("_CodeSignature") {
            return true
        }
        if name.hasSuffix("/embedded.mobileprovision") {
            return true
        }
        return false
    }

    /// Sanitizes an untrusted IPA `version` or `build` string into a safe single-component filename token,
    /// rejecting path separators (`/` / `\`), `..` traversal, and control characters.
    public static func sanitizeFilenameToken(_ raw: String, fallback: String) -> String {
        let filtered = raw.unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            let isAlnum = (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
            let isSafePunct = (v == 0x2E || v == 0x2D || v == 0x5F) // . - _
            return (isAlnum || isSafePunct) ? Character(scalar) : "_"
        }
        var token = String(filtered)
        while token.contains("..") {
            token = token.replacingOccurrences(of: "..", with: "_")
        }
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        if token.isEmpty {
            return fallback
        }
        return String(token.prefix(32))
    }

    public static func makeSafeExportFilename(
        version: String,
        build: String,
        applyCustomBiliIcons: Bool
    ) -> String {
        let safeVer = sanitizeFilenameToken(version, fallback: "unknown")
        let safeBuild = sanitizeFilenameToken(build, fallback: "0")
        let iconTag = applyCustomBiliIcons ? "" : "-origicon"
        let candidate = "Arknights-\(safeVer)-b\(safeBuild)-bili\(iconTag)-unsigned.ipa"
        // Extra defense: enforce single path component.
        assert(!candidate.contains("/") && !candidate.contains("\\") && !candidate.contains(".."))
        return candidate
    }

    public func apply(
        configuration: MatchedPatchConfiguration,
        sourceIPAURL: URL,
        workingDirectory: URL,
        options: PatchOptions = .default,
        inputSession: PatchInputSession? = nil,
        preloadedKit: LoadedVerifiedKit? = nil,
        overwriteExistingOutput: Bool = false,
        onProgress: (@Sendable (PatchProgress) -> Void)? = nil
    ) throws -> PatchExecutionResult {
        let startTime = Date()
        try Task.checkCancellation()

        // Step A: Reuse pre-verified kit overlay when supplied by the same pipeline invocation,
        // avoiding redundant decompression & SHA-256 hashing of all 200+ payload entries.
        let loadedKit: LoadedVerifiedKit
        if let preloadedKit,
           preloadedKit.verifiedKit.profile == configuration.profile,
           preloadedKit.verifiedKit.manifestSHA256 == configuration.verifiedKit.manifestSHA256 {
            onProgress?(
                PatchProgress(
                    stage: .preflightValidating,
                    fractionCompleted: 0.05,
                    detailMessage: "正在准备补丁组件…"
                )
            )
            loadedKit = preloadedKit
        } else {
            onProgress?(
                PatchProgress(
                    stage: .preflightValidating,
                    fractionCompleted: 0.05,
                    detailMessage: "正在校验并加载补丁组件…"
                )
            )
            let verifier = KitIntegrityVerifier()
            loadedKit = try verifier.loadAndVerifyOverlay(profile: configuration.profile)
        }
        let manifest = loadedKit.verifiedKit.manifest

        // Step B: Reuse scoped read-only session (single FD & cached UnityFramework) or open read-only once.
        onProgress?(
            PatchProgress(
                stage: .preflightValidating,
                fractionCompleted: 0.20,
                detailMessage: "正在检查安装包版本与砸壳状态…"
            )
        )
        let session: PatchInputSession
        if let provided = inputSession,
           provided.sourceURL.standardizedFileURL == sourceIPAURL.standardizedFileURL {
            session = provided
        } else {
            session = try PatchInputSession(ipaURL: sourceIPAURL)
        }
        let sourceReader = session.reader

        let freshHostProfile: HostIPAProfile
        if let cachedProfile = session.hostProfile {
            freshHostProfile = cachedProfile
        } else {
            freshHostProfile = try HostInspector().inspect(session: session, options: .default)
        }

        let matcher = CompatibilityMatcher()
        let preflightMismatches: [CompatibilityMismatch]
        switch configuration.adaptationMode {
        case .builtInVerified:
            preflightMismatches = matcher.evaluateMismatches(host: freshHostProfile, manifest: manifest)
        case .manualCustomProfile, .autoResolved:
            guard let rtProfile = configuration.runtimeOffsetProfile else {
                throw PatchError.invalidCustomProfile("缺少对应的运行时偏移配置文件")
            }
            try rtProfile.validate()
            if configuration.adaptationMode == .autoResolved,
               let report = configuration.autoResolutionReport,
               !report.isConfirmedCompatible {
                throw PatchError.autoResolutionFailed("自动定位尚未确认 ABI 兼容，已禁止写入输出")
            }
            preflightMismatches = matcher.evaluateRuntimeProfileMismatches(
                host: freshHostProfile,
                profile: rtProfile,
                expectedAppRoot: manifest.appRoot
            )
        }

        if !preflightMismatches.isEmpty {
            if freshHostProfile.isEncrypted {
                throw PatchError.encryptedHostIPA(binaries: freshHostProfile.encryptedBinaryPaths)
            }
            throw PatchError.incompatibleHost(
                IncompatibilityReport(
                    actualBundleID: freshHostProfile.bundleID,
                    actualVersion: freshHostProfile.version,
                    actualBuild: freshHostProfile.build,
                    actualAppRoot: freshHostProfile.appRoot,
                    isEncrypted: freshHostProfile.isEncrypted,
                    targetRevision: configuration.effectiveRevision,
                    targetVersion: configuration.runtimeOffsetProfile?.version ?? manifest.version,
                    targetBuild: configuration.runtimeOffsetProfile?.build ?? manifest.build,
                    mismatches: preflightMismatches
                )
            )
        }

        // Step C: Unified binary modification pipeline across built-in, manual, and auto modes.
        // Only read & modify host binaries that ACTUALLY require patching or dynamic injection;
        // unmodified host binaries remain zero-copy streaming passthrough!
        onProgress?(
            PatchProgress(
                stage: .preflightValidating,
                fractionCompleted: 0.50,
                detailMessage: "正在写入 B 服桥接组件…"
            )
        )
        var overlay = loadedKit.payloadOverlay

        if !options.applyCustomBiliIcons {
            let iconPrefix = manifest.appRoot + "ABAppIcon"
            for key in Array(overlay.keys) where key.hasPrefix(iconPrefix) && key.hasSuffix(".png") {
                overlay.removeValue(forKey: key)
            }
        }

        if let rtProfile = configuration.runtimeOffsetProfile {
            let runtimePlistPath = manifest.appRoot + "ABRuntimeProfile.plist"
            overlay[runtimePlistPath] = try rtProfile.encodeToRuntimeProfilePlistData()
        }

        var binariesToModify = Set<String>()
        if configuration.adaptationMode == .builtInVerified {
            for p in manifest.binaryPatches.keys {
                binariesToModify.insert(p)
            }
        }
        if let dynSpec = manifest.dynamicDylibInjection {
            binariesToModify.insert(dynSpec.targetBinary)
        } else if configuration.adaptationMode != .builtInVerified {
            throw PatchError.unsupportedManifestProfile("当前补丁底座不支持动态 Mach-O 注入")
        }

        let unityRelPath = manifest.appRoot + "Frameworks/UnityFramework.framework/UnityFramework"
        var hostModifiedPaths = Set<String>()

        for binaryPath in binariesToModify.sorted() {
            try Task.checkCancellation()
            var raw: Data
            if binaryPath == unityRelPath {
                // Take unique ownership out of session cache to avoid ~200 MB CoW duplication during injection.
                raw = try session.takeUnityFrameworkData(at: binaryPath)
            } else {
                do {
                    raw = try sourceReader.readData(named: binaryPath)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let zipError as ZipError {
                    throw PatchError.zipFailure(zipError)
                }
            }

            // Preflight-verify runtime offset alignment & Mach-O segment bounds for custom/auto profiles BEFORE writing output.
            if binaryPath == unityRelPath,
               let rtProfile = configuration.runtimeOffsetProfile {
                let offsetMismatches = MachOParser.validateRuntimeOffsets(rtProfile.il2cppOffsets, againstMachOData: raw)
                if !offsetMismatches.isEmpty {
                    throw PatchError.incompatibleHost(
                        IncompatibilityReport(
                            actualBundleID: freshHostProfile.bundleID,
                            actualVersion: freshHostProfile.version,
                            actualBuild: freshHostProfile.build,
                            actualAppRoot: freshHostProfile.appRoot,
                            isEncrypted: freshHostProfile.isEncrypted,
                            targetRevision: rtProfile.revision,
                            targetVersion: rtProfile.version,
                            targetBuild: rtProfile.build,
                            mismatches: offsetMismatches
                        )
                    )
                }
            }

            // Preflight-verify optional `__TEXT.__text` digest for custom/auto profiles BEFORE injecting or writing output.
            if binaryPath == unityRelPath,
               let rtProfile = configuration.runtimeOffsetProfile,
               let expectedTextSize = rtProfile.unityTextSize,
               let expectedTextSHA = rtProfile.unityTextSHA256 {
                let actualDigest = MachOParser.extractPrimaryTextDigest(data: raw)
                let sizeOK = actualDigest?.size == expectedTextSize
                let shaOK = actualDigest?.sha256 == expectedTextSHA.lowercased()
                if !sizeOK || !shaOK {
                    let expectedDesc = "\(IL2CPPOffsetSet.hexString(expectedTextSize)) / \(expectedTextSHA.prefix(16))…"
                    let actualDesc: String = {
                        if let actualDigest {
                            return "\(IL2CPPOffsetSet.hexString(actualDigest.size)) / \(actualDigest.sha256.prefix(16))…"
                        }
                        return "未找到有效的 __TEXT.__text 代码段"
                    }()
                    let mismatch = CompatibilityMismatch(
                        kind: .binaryTextDigest,
                        fieldLabel: "代码段指纹 · UnityFramework __text",
                        expected: expectedDesc,
                        actual: actualDesc,
                        detail: "配置文件中声明的 unityTextSize / unityTextSHA256 与宿主 UnityFramework 实际代码段不一致，继续导出会在启动游戏时被桥接安全检查拒绝。请更新配置文件的代码段指纹，或同时省略这两项以仅按 UUID 校验。"
                    )
                    throw PatchError.incompatibleHost(
                        IncompatibilityReport(
                            actualBundleID: freshHostProfile.bundleID,
                            actualVersion: freshHostProfile.version,
                            actualBuild: freshHostProfile.build,
                            actualAppRoot: freshHostProfile.appRoot,
                            isEncrypted: freshHostProfile.isEncrypted,
                            targetRevision: rtProfile.revision,
                            targetVersion: rtProfile.version,
                            targetBuild: rtProfile.build,
                            mismatches: [mismatch]
                        )
                    )
                }
            }

            if configuration.adaptationMode == .builtInVerified,
               let patchSpec = manifest.binaryPatches[binaryPath] {
                raw = try BinaryRangePatcher.apply(raw: raw, spec: patchSpec, binaryPath: binaryPath)
            }
            if let dynSpec = manifest.dynamicDylibInjection, dynSpec.targetBinary == binaryPath {
                _ = try MachODylibInjector.injectInPlace(
                    dylibLoadPath: dynSpec.dylibLoadPath,
                    into: &raw,
                    binaryPath: binaryPath
                )
            }
            overlay[binaryPath] = raw
            hostModifiedPaths.insert(binaryPath)
        }

        // Ensure session cache is released before repackaging.
        session.releaseUnityCache()

        // Step D: Dynamically merge B-server delta into host Info.plist & verify metadata.
        onProgress?(
            PatchProgress(
                stage: .preflightValidating,
                fractionCompleted: 0.80,
                detailMessage: "正在更新游戏配置与桌面图标信息…"
            )
        )
        let effectiveRevision = configuration.effectiveRevision
        let patchedInfoPath = manifest.appRoot + "Info.plist"
        if overlay[patchedInfoPath] == nil {
            let hostInfoData: Data
            do {
                hostInfoData = try sourceReader.readData(named: patchedInfoPath)
            } catch is CancellationError {
                throw CancellationError()
            } catch let zipError as ZipError {
                throw PatchError.zipFailure(zipError)
            }
            overlay[patchedInfoPath] = try HostInfoPlistPatcher.patch(
                hostInfoPlistData: hostInfoData,
                revision: effectiveRevision,
                expectedBundleID: manifest.bundleID,
                applyCustomBiliIcons: options.applyCustomBiliIcons
            )
        }
        guard let patchedInfoData = overlay[patchedInfoPath] else {
            throw PatchError.invalidPatchedMetadata("缺少补丁后的 \(patchedInfoPath)")
        }
        let patchedPlistObj = try PropertyListSerialization.propertyList(from: patchedInfoData, options: [], format: nil)
        guard let patchedInfo = patchedPlistObj as? [String: Any],
              (patchedInfo["CFBundleIdentifier"] as? String) == manifest.bundleID,
              patchedInfo["ABPackagingRevision"] != nil else {
            throw PatchError.invalidPatchedMetadata("补丁后 Info.plist 缺少 ABPackagingRevision 或包名不匹配")
        }

        for (path, raw) in overlay where hostModifiedPaths.contains(path) || path.hasSuffix(".dylib") {
            try Task.checkCancellation()
            let slices = try MachOParser.parseSlices(data: raw, binaryPath: path, includeSHA256: false)
            if slices.contains(where: \.isEncrypted) {
                throw PatchError.encryptedOutputBinary(path)
            }
        }

        var overlayExpectedSHA256: [String: String] = [:]
        overlayExpectedSHA256.reserveCapacity(overlay.count)
        for (path, data) in overlay {
            overlayExpectedSHA256[path] = SHA256.hash(data: data).hexString
        }

        // Step E: Prepare safe single-component final filename & isolated fixed temp `.partial` path.
        // Never overwrite an existing final output unless `overwriteExistingOutput == true` (and even then,
        // only atomically replace AFTER full output verification succeeds!).
        let suggestedFilename = Self.makeSafeExportFilename(
            version: freshHostProfile.version,
            build: freshHostProfile.build,
            applyCustomBiliIcons: options.applyCustomBiliIcons
        )
        let finalURL = workingDirectory.appendingPathComponent(suggestedFilename, isDirectory: false)
        guard finalURL.deletingLastPathComponent().standardizedFileURL == workingDirectory.standardizedFileURL else {
            throw PatchError.ioFailure("输出文件名包含非法路径层级：\(suggestedFilename)")
        }

        if FileManager.default.fileExists(atPath: finalURL.path) && !overwriteExistingOutput {
            throw PatchError.outputAlreadyExists(finalURL.path)
        }

        let partialURL = workingDirectory.appendingPathComponent(
            ".arknights-patch-\(UUID().uuidString).partial",
            isDirectory: false
        )
        guard sourceIPAURL.standardizedFileURL != finalURL.standardizedFileURL,
              sourceIPAURL.standardizedFileURL != partialURL.standardizedFileURL else {
            throw PatchError.ioFailure("输出路径不能与源 IPA 相同")
        }

        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        onProgress?(
            PatchProgress(
                stage: .preflightValidating,
                fractionCompleted: 1.0,
                detailMessage: "检查全部通过，即将开始打包…"
            )
        )

        // Step F: Single-pass streaming ZIP64 repackage into `.partial`.
        let writer: Zip64Writer
        do {
            writer = try Zip64Writer(url: partialURL)
        } catch let zipError as ZipError {
            throw PatchError.zipFailure(zipError)
        }

        var removedEntries: [String] = []
        var modifiedEntries: [String] = []
        var addedEntries: [String] = []
        var writtenNames = Set<String>()
        var unchangedFingerprints: [String: (crc32: UInt32, size: UInt64)] = [:]

        do {
            let sourceEntries = sourceReader.entries
            let totalBytesToCopy: UInt64 = sourceEntries.reduce(UInt64(0)) { acc, entry in
                if Self.shouldStripEntry(entry.name) { return acc }
                if let overlayData = overlay[entry.name] { return acc &+ UInt64(overlayData.count) }
                return acc &+ entry.compressedSize
            } &+ overlay.reduce(UInt64(0)) { acc, kv in
                sourceReader.entry(named: kv.key) == nil ? acc &+ UInt64(kv.value.count) : acc
            }

            let totalSteps = sourceEntries.count + overlay.count
            var processedBytes: UInt64 = 0
            var processedCount = 0

            for original in sourceEntries {
                try Task.checkCancellation()
                let name = original.name

                if Self.shouldStripEntry(name) {
                    removedEntries.append(name)
                    processedCount += 1
                    continue
                }

                if let overlayData = overlay.removeValue(forKey: name) {
                    let written = try writer.writeDeflatedEntry(
                        name: name,
                        data: overlayData,
                        versionMadeBy: original.versionMadeBy,
                        externalAttributes: original.externalFileAttributes,
                        dosTime: original.dosTime,
                        dosDate: original.dosDate
                    )
                    if original.crc32 != written.crc32 || original.uncompressedSize != written.uncompressedSize {
                        modifiedEntries.append(name)
                    }
                    processedBytes &+= UInt64(overlayData.count)
                } else if original.isDirectory {
                    try writer.writeDirectoryEntry(
                        name: name,
                        versionMadeBy: original.versionMadeBy,
                        externalAttributes: original.externalFileAttributes,
                        dosTime: original.dosTime,
                        dosDate: original.dosDate
                    )
                } else {
                    try writer.copyRawEntry(from: sourceReader, entry: original) { delta in
                        processedBytes &+= delta
                        let frac = totalBytesToCopy > 0 ? min(0.99, Double(processedBytes) / Double(totalBytesToCopy)) : 0
                        onProgress?(
                            PatchProgress(
                                stage: .repackaging,
                                fractionCompleted: frac,
                                completedEntries: processedCount,
                                totalEntries: totalSteps,
                                processedBytes: processedBytes,
                                totalBytes: totalBytesToCopy,
                                detailMessage: "正在写入游戏资源：\(URL(fileURLWithPath: name).lastPathComponent)"
                            )
                        )
                    }
                    unchangedFingerprints[name] = (original.crc32, original.uncompressedSize)
                }

                writtenNames.insert(name)
                processedCount += 1

                if processedCount % 16 == 0 || processedCount == sourceEntries.count {
                    let frac = totalBytesToCopy > 0 ? min(0.95, Double(processedBytes) / Double(totalBytesToCopy)) : 0.5
                    onProgress?(
                        PatchProgress(
                            stage: .repackaging,
                            fractionCompleted: frac,
                            completedEntries: processedCount,
                            totalEntries: totalSteps,
                            processedBytes: processedBytes,
                            totalBytes: totalBytesToCopy,
                            detailMessage: "正在打包游戏文件（\(processedCount)/\(sourceEntries.count)）…"
                        )
                    )
                }
            }

            let newEntryNames = Set(overlay.keys).subtracting(writtenNames).sorted()
            // Emit explicit parent directory entries for newly added nested bundles/folders if not yet present.
            var missingParentDirs = Set<String>()
            for name in newEntryNames {
                let parts = name.split(separator: "/")
                if parts.count > 1 {
                    var prefix = ""
                    for component in parts.dropLast() {
                        prefix += component + "/"
                        if !writtenNames.contains(prefix) {
                            missingParentDirs.insert(prefix)
                        }
                    }
                }
            }
            for dirName in missingParentDirs.sorted() {
                try Task.checkCancellation()
                try writer.writeDirectoryEntry(name: dirName)
                writtenNames.insert(dirName)
            }

            for name in newEntryNames {
                try Task.checkCancellation()
                guard let data = overlay.removeValue(forKey: name) else { continue }
                let posixMode: UInt32 = name.hasSuffix(".dylib") ? 0o100755 : 0o100644
                try writer.writeDeflatedEntry(
                    name: name,
                    data: data,
                    versionMadeBy: ZipConstants.unixCreatorSystem | 45,
                    externalAttributes: posixMode << 16
                )
                addedEntries.append(name)
                writtenNames.insert(name)
                processedBytes &+= UInt64(data.count)
                processedCount += 1
            }

            // Release all remaining overlay buffers before full output verification.
            overlay.removeAll(keepingCapacity: false)

            onProgress?(
                PatchProgress(
                    stage: .repackaging,
                    fractionCompleted: 0.99,
                    completedEntries: writtenNames.count,
                    totalEntries: writtenNames.count,
                    processedBytes: processedBytes,
                    totalBytes: max(totalBytesToCopy, processedBytes),
                    detailMessage: "正在完成安装包封装…"
                )
            )
            try writer.finish()

            // Step G: Mandatory full output verification BEFORE exposing final file.
            // Scoped so `outReader` closes its file descriptor before atomic `moveItem`/`replaceItemAt`.
            onProgress?(
                PatchProgress(
                    stage: .verifyingOutput,
                    fractionCompleted: 0.02,
                    detailMessage: "正在核对成品安装包完整性…"
                )
            )
            let outputBytes: UInt64
            let totalVerifyEntries: Int
            var verifiedBytes: UInt64 = 0
            let totalVerifyBytes: UInt64

            do {
                let outReader = try Zip64Reader(url: partialURL)
                let expectedInventory = writtenNames.union(Set(overlayExpectedSHA256.keys))
                let actualInventory = Set(outReader.entryNames)
                guard actualInventory == expectedInventory else {
                    throw PatchError.outputVerificationFailed(
                        "输出条目清单不一致（期望 \(expectedInventory.count) 项，实际 \(actualInventory.count) 项）"
                    )
                }

                totalVerifyEntries = outReader.entries.count
                totalVerifyBytes = outReader.entries.reduce(UInt64(0)) { $0 &+ $1.uncompressedSize }

                for (idx, entry) in outReader.entries.enumerated() {
                    try Task.checkCancellation()

                    if let expectedHash = overlayExpectedSHA256[entry.name] {
                        var hasher = SHA256()
                        try outReader.streamDecompressedBuffer(entry: entry) { buffer in
                            hasher.update(bufferPointer: buffer)
                            verifiedBytes &+= UInt64(buffer.count)
                        }
                        let actualHash = hasher.finalize().hexString
                        guard actualHash == expectedHash else {
                            throw PatchError.outputVerificationFailed("补丁输出哈希不一致：\(entry.name)")
                        }
                    } else {
                        try outReader.streamDecompressedBuffer(entry: entry) { buffer in
                            verifiedBytes &+= UInt64(buffer.count)
                        }
                        if let expectedFP = unchangedFingerprints[entry.name] {
                            guard entry.crc32 == expectedFP.crc32 && entry.uncompressedSize == expectedFP.size else {
                                throw PatchError.outputVerificationFailed("保留资源发生意外变更：\(entry.name)")
                            }
                        }
                    }

                    if (idx + 1) % 16 == 0 || (idx + 1) == totalVerifyEntries {
                        let frac = totalVerifyBytes > 0
                            ? min(0.92, Double(verifiedBytes) / Double(totalVerifyBytes) * 0.92)
                            : (Double(idx + 1) / Double(max(1, totalVerifyEntries)) * 0.92)
                        onProgress?(
                            PatchProgress(
                                stage: .verifyingOutput,
                                fractionCompleted: frac,
                                completedEntries: idx + 1,
                                totalEntries: totalVerifyEntries,
                                processedBytes: verifiedBytes,
                                totalBytes: totalVerifyBytes,
                                detailMessage: "正在校验文件完整性（\(idx + 1)/\(totalVerifyEntries)）…"
                            )
                        )
                    }
                }

                outputBytes = outReader.fileSize
            }

            // Atomic commit `.partial` -> `finalURL` ONLY after 100% verification succeeds.
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: finalURL.path) {
                if overwriteExistingOutput {
                    _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: partialURL)
                } else {
                    throw PatchError.outputAlreadyExists(finalURL.path)
                }
            } else {
                try FileManager.default.moveItem(at: partialURL, to: finalURL)
            }

            onProgress?(
                PatchProgress(
                    stage: .verifyingOutput,
                    fractionCompleted: 1.0,
                    completedEntries: totalVerifyEntries,
                    totalEntries: totalVerifyEntries,
                    processedBytes: verifiedBytes,
                    totalBytes: totalVerifyBytes,
                    detailMessage: "全部校验通过，已可安全导出"
                )
            )

            return PatchExecutionResult(
                outputURL: finalURL,
                suggestedExportFilename: suggestedFilename,
                hostProfile: freshHostProfile,
                revision: effectiveRevision,
                outputBytes: outputBytes,
                preservedSourceFiles: unchangedFingerprints.count,
                modifiedEntries: modifiedEntries,
                addedEntries: addedEntries,
                removedEntries: removedEntries,
                zipCRCVerified: true,
                durationSeconds: Date().timeIntervalSince(startTime),
                adaptationMode: configuration.adaptationMode,
                appliedCustomBiliIcons: options.applyCustomBiliIcons,
                profileDisplayName: configuration.runtimeOffsetProfile?.name,
                generatedRuntimeProfile: configuration.adaptationMode == .autoResolved ? configuration.runtimeOffsetProfile : nil
            )
        } catch is CancellationError {
            writer.abortAndRemove()
            try? FileManager.default.removeItem(at: partialURL)
            throw CancellationError()
        } catch let zipError as ZipError {
            writer.abortAndRemove()
            try? FileManager.default.removeItem(at: partialURL)
            throw PatchError.zipFailure(zipError)
        } catch {
            writer.abortAndRemove()
            try? FileManager.default.removeItem(at: partialURL)
            throw error
        }
    }
}
