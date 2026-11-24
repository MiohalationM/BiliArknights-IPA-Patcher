import Foundation

public struct PatchKitManifest: Sendable, Hashable, Codable {
    public struct HostBinaryExpectation: Sendable, Hashable, Codable {
        public let uuid: String
        public let sha256: String?
    }

    public struct BinaryPatchRange: Sendable, Hashable, Codable {
        public let offset: Int
        public let before: String
        public let after: String
    }

    public struct BinaryPatchSpec: Sendable, Hashable, Codable {
        public let beforeSHA256: String?
        public let afterSHA256: String?
        public let ranges: [BinaryPatchRange]

        enum CodingKeys: String, CodingKey {
            case beforeSHA256 = "before_sha256"
            case afterSHA256 = "after_sha256"
            case ranges
        }
    }

    public struct DynamicDylibInjectionSpec: Sendable, Hashable, Codable {
        public let targetBinary: String
        public let dylibLoadPath: String

        enum CodingKeys: String, CodingKey {
            case targetBinary = "target_binary"
            case dylibLoadPath = "dylib_load_path"
        }
    }

    public let schema: Int
    public let revision: String
    public let bundleID: String
    public let version: String
    public let build: String
    public let appRoot: String
    public let inputHashAllowlistUsed: Bool?
    public let hostBinaries: [String: HostBinaryExpectation]
    public let binaryPatches: [String: BinaryPatchSpec]
    public let dynamicDylibInjection: DynamicDylibInjectionSpec?
    public let payloadSHA256: String
    public let payloadEntries: [String: String]
    public let runtimeNote: String?
    public let encryptionPolicy: String?
    public let sdk: String?

    enum CodingKeys: String, CodingKey {
        case schema
        case revision
        case bundleID = "bundle_id"
        case version
        case build
        case appRoot = "app_root"
        case inputHashAllowlistUsed = "input_hash_allowlist_used"
        case hostBinaries = "host_binaries"
        case binaryPatches = "binary_patches"
        case dynamicDylibInjection = "dynamic_dylib_injection"
        case payloadSHA256 = "payload_sha256"
        case payloadEntries = "payload_entries"
        case runtimeNote = "runtime_note"
        case encryptionPolicy = "encryption_policy"
        case sdk
    }
}

/// Identifies a trusted patch kit and its pinned cryptographic fingerprint.
public struct TrustedPatchProfile: Sendable, Hashable {
    public let identifier: String
    public let displayTitle: String
    public let expectedRevision: String
    public let expectedVersion: String
    public let expectedBuild: String
    public let lockedManifestSHA256: String
    public let manifestURL: URL
    public let payloadZipURL: URL

    public init(
        identifier: String,
        displayTitle: String,
        expectedRevision: String,
        expectedVersion: String,
        expectedBuild: String,
        lockedManifestSHA256: String,
        manifestURL: URL,
        payloadZipURL: URL
    ) {
        self.identifier = identifier
        self.displayTitle = displayTitle
        self.expectedRevision = expectedRevision
        self.expectedVersion = expectedVersion
        self.expectedBuild = expectedBuild
        self.lockedManifestSHA256 = lockedManifestSHA256
        self.manifestURL = manifestURL
        self.payloadZipURL = payloadZipURL
    }
}

public struct VerifiedPatchKit: Sendable, Hashable {
    public let profile: TrustedPatchProfile
    public let manifest: PatchKitManifest
    public let manifestSHA256: String
    public let payloadZipSHA256: String
    public let payloadEntryCount: Int
}

public enum BuiltInKitRepository {
    public static let lockedManifestSHA256 = "e195d85e2efd5eecf48a581e6108f9346f482fa8a6835baa740155ede5ff7c47"
    public static let activeRevision = "7.5-2.7.91-bridge-carrier-r5"
    public static let activeVersion = "2.7.91"
    public static let activeBuild = "76"

    /// Resolves the built-in static bridge + official SDK carrier kit bundled inside `IPAPatcherCore`.
    public static func builtInDefaultProfile() throws -> TrustedPatchProfile {
        guard let manifestURL = Bundle.module.url(
            forResource: "manifest",
            withExtension: "json",
            subdirectory: "Kits/carrier-2.7.91"
        ) else {
            throw PatchError.missingBuiltInKit("未在资源包中找到 Kits/carrier-2.7.91/manifest.json")
        }
        guard let payloadURL = Bundle.module.url(
            forResource: "payload",
            withExtension: "zip",
            subdirectory: "Kits/carrier-2.7.91"
        ) else {
            throw PatchError.missingBuiltInKit("未在资源包中找到 Kits/carrier-2.7.91/payload.zip")
        }

        return TrustedPatchProfile(
            identifier: "arknights-2.7.91-b76-bridge-carrier-r5",
            displayTitle: "明日方舟 2.7.91 (build 76) · 源码桥接 + 官方 B 站 SDK",
            expectedRevision: activeRevision,
            expectedVersion: activeVersion,
            expectedBuild: activeBuild,
            lockedManifestSHA256: lockedManifestSHA256,
            manifestURL: manifestURL,
            payloadZipURL: payloadURL
        )
    }

    public static func allBuiltInProfiles() throws -> [TrustedPatchProfile] {
        [try builtInDefaultProfile()]
    }

    /// Creates a profile backed by an external directory on disk (useful for macOS CLI & future sample testing).
    public static func externalProfile(
        kitDirectory: URL,
        revision: String = activeRevision,
        version: String = activeVersion,
        build: String = activeBuild,
        lockedManifestSHA256: String = lockedManifestSHA256
    ) -> TrustedPatchProfile {
        TrustedPatchProfile(
            identifier: "external-\(revision)",
            displayTitle: "外部补丁目录（\(revision)）",
            expectedRevision: revision,
            expectedVersion: version,
            expectedBuild: build,
            lockedManifestSHA256: lockedManifestSHA256,
            manifestURL: kitDirectory.appendingPathComponent("manifest.json"),
            payloadZipURL: kitDirectory.appendingPathComponent("payload.zip")
        )
    }
}
