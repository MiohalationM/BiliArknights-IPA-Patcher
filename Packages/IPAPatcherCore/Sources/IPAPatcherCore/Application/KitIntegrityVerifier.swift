import CryptoKit
import Foundation
import Zip64Kit

public struct LoadedVerifiedKit: Sendable {
    public let verifiedKit: VerifiedPatchKit
    public let payloadOverlay: [String: Data]
}

/// Verifies the built-in or external patch kit (`manifest.json` + `payload.zip` + all payload entry SHA-256 hashes)
/// before any host patching is allowed.
public struct KitIntegrityVerifier: Sendable {
    public init() {}

    /// Verifies `manifest.json` hash, schema/revision fields, `payload.zip` hash, and optionally every entry hash inside `payload.zip`.
    public func verifyKit(
        profile: TrustedPatchProfile,
        verifyPayloadEntries: Bool = true
    ) throws -> VerifiedPatchKit {
        let loaded = try loadAndVerifyKit(profile: profile, retainOverlayData: false, verifyPayloadEntries: verifyPayloadEntries)
        return loaded.verifiedKit
    }

    public func loadAndVerifyOverlay(profile: TrustedPatchProfile) throws -> LoadedVerifiedKit {
        try loadAndVerifyKit(profile: profile, retainOverlayData: true, verifyPayloadEntries: true)
    }

    private func loadAndVerifyKit(
        profile: TrustedPatchProfile,
        retainOverlayData: Bool,
        verifyPayloadEntries: Bool
    ) throws -> LoadedVerifiedKit {
        try Task.checkCancellation()

        guard FileManager.default.fileExists(atPath: profile.manifestURL.path) else {
            throw PatchError.missingBuiltInKit("缺少 manifest.json：\(profile.manifestURL.path)")
        }
        let manifestRaw: Data
        do {
            manifestRaw = try Data(contentsOf: profile.manifestURL)
        } catch {
            throw PatchError.ioFailure("无法读取 manifest.json：\(error.localizedDescription)")
        }

        let actualManifestSHA = SHA256.hash(data: manifestRaw).hexString
        guard actualManifestSHA == profile.lockedManifestSHA256 else {
            throw PatchError.lockedManifestHashMismatch(
                expected: profile.lockedManifestSHA256,
                actual: actualManifestSHA
            )
        }

        let manifest: PatchKitManifest
        do {
            manifest = try JSONDecoder().decode(PatchKitManifest.self, from: manifestRaw)
        } catch {
            throw PatchError.unsupportedManifestProfile("manifest.json JSON 解析失败：\(error.localizedDescription)")
        }

        guard manifest.schema == 1,
              manifest.revision == profile.expectedRevision,
              manifest.version == profile.expectedVersion,
              manifest.build == profile.expectedBuild else {
            throw PatchError.unsupportedManifestProfile(
                "schema=\(manifest.schema), revision=\(manifest.revision), version=\(manifest.version), build=\(manifest.build)"
            )
        }

        guard FileManager.default.fileExists(atPath: profile.payloadZipURL.path) else {
            throw PatchError.missingBuiltInKit("缺少 payload.zip：\(profile.payloadZipURL.path)")
        }
        let actualPayloadSHA = try FileHasher.sha256Hex(of: profile.payloadZipURL)
        guard actualPayloadSHA == manifest.payloadSHA256 else {
            throw PatchError.payloadZipHashMismatch(
                expected: manifest.payloadSHA256,
                actual: actualPayloadSHA
            )
        }

        var overlay: [String: Data] = [:]
        var verifiedEntryCount = manifest.payloadEntries.count

        if verifyPayloadEntries || retainOverlayData {
            let kitReader: Zip64Reader
            do {
                kitReader = try Zip64Reader(url: profile.payloadZipURL)
            } catch let zipError as ZipError {
                throw PatchError.zipFailure(zipError)
            }

            var actualFingerprints: [String: String] = [:]
            actualFingerprints.reserveCapacity(kitReader.entries.count)
            if retainOverlayData {
                overlay.reserveCapacity(kitReader.entries.count)
            }

            for entry in kitReader.entries where !entry.isDirectory {
                try Task.checkCancellation()
                guard entry.name.hasPrefix(manifest.appRoot) else {
                    throw PatchError.patchPathOutsideAppRoot(entry.name)
                }
                let entryData: Data
                do {
                    entryData = try kitReader.readData(for: entry)
                } catch let zipError as ZipError {
                    throw PatchError.zipFailure(zipError)
                }
                actualFingerprints[entry.name] = SHA256.hash(data: entryData).hexString
                if retainOverlayData {
                    overlay[entry.name] = entryData
                }
            }

            guard actualFingerprints == manifest.payloadEntries else {
                let expectedKeys = Set(manifest.payloadEntries.keys)
                let actualKeys = Set(actualFingerprints.keys)
                let missing = expectedKeys.subtracting(actualKeys).sorted()
                let extra = actualKeys.subtracting(expectedKeys).sorted()
                let hashMismatch = expectedKeys.intersection(actualKeys).filter {
                    manifest.payloadEntries[$0] != actualFingerprints[$0]
                }.sorted()
                let detail = "缺失 \(missing.count) 项，多余 \(extra.count) 项，哈希不一致 \(hashMismatch.count) 项"
                throw PatchError.payloadEntryMismatch(detail)
            }
            verifiedEntryCount = actualFingerprints.count
        }

        let verifiedKit = VerifiedPatchKit(
            profile: profile,
            manifest: manifest,
            manifestSHA256: actualManifestSHA,
            payloadZipSHA256: actualPayloadSHA,
            payloadEntryCount: verifiedEntryCount
        )
        return LoadedVerifiedKit(verifiedKit: verifiedKit, payloadOverlay: overlay)
    }
}
