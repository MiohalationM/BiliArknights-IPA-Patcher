import Foundation
import Zip64Kit

// MARK: - Next-Stage Extension Interfaces
// Reserved in the Host Identification layer for future macOS sample-comparison iteration
// and cross-version candidate location before handing off to the PatchApplicator.

/// Structural features extracted from a host IPA binary for cross-version comparison.
public struct HostBinaryFeature: Sendable, Hashable, Codable {
    public let binaryPath: String
    public let architecture: String
    public let uuid: String?
    public let segmentNames: [String]
    public let sectionFingerprints: [String: String]
    public let symbolAnchors: [String: UInt64]
    public let metadataNotes: [String: String]

    public init(
        binaryPath: String,
        architecture: String,
        uuid: String?,
        segmentNames: [String] = [],
        sectionFingerprints: [String: String] = [:],
        symbolAnchors: [String: UInt64] = [:],
        metadataNotes: [String: String] = [:]
    ) {
        self.binaryPath = binaryPath
        self.architecture = architecture
        self.uuid = uuid
        self.segmentNames = segmentNames
        self.sectionFingerprints = sectionFingerprints
        self.symbolAnchors = symbolAnchors
        self.metadataNotes = metadataNotes
    }
}

/// Complete feature snapshot of a host IPA, serializable for offline macOS sample comparison.
public struct HostFeatureSet: Sendable, Hashable, Codable {
    public let hostProfile: HostIPAProfile
    public let binaryFeatures: [HostBinaryFeature]
    public let extractorIdentifier: String

    public init(
        hostProfile: HostIPAProfile,
        binaryFeatures: [HostBinaryFeature],
        extractorIdentifier: String
    ) {
        self.hostProfile = hostProfile
        self.binaryFeatures = binaryFeatures
        self.extractorIdentifier = extractorIdentifier
    }
}

/// A candidate patch range located by comparing a newer host IPA against a reference baseline.
public struct PatchCandidate: Sendable, Hashable, Codable {
    public let binaryPath: String
    public let offset: Int
    public let expectedPreimageHex: String
    public let proposedReplacementHex: String
    public let confidence: Double
    public let rationale: String

    public init(
        binaryPath: String,
        offset: Int,
        expectedPreimageHex: String,
        proposedReplacementHex: String,
        confidence: Double,
        rationale: String
    ) {
        self.binaryPath = binaryPath
        self.offset = offset
        self.expectedPreimageHex = expectedPreimageHex
        self.proposedReplacementHex = proposedReplacementHex
        self.confidence = confidence
        self.rationale = rationale
    }
}

/// Result of checking whether a bridge library is ABI/hook-compatible with a candidate host version
/// before handing the located patch candidates to the application engine.
public struct BridgeCompatibilityAssessment: Sendable, Hashable, Codable {
    public enum Verdict: String, Sendable, Hashable, Codable {
        case compatible
        case requiresManualVerification
        case incompatible
    }

    public let verdict: Verdict
    public let bridgeRevision: String
    public let checkedHooks: [String]
    public let warnings: [String]
    public let blockers: [String]

    public init(
        verdict: Verdict,
        bridgeRevision: String,
        checkedHooks: [String] = [],
        warnings: [String] = [],
        blockers: [String] = []
    ) {
        self.verdict = verdict
        self.bridgeRevision = bridgeRevision
        self.checkedHooks = checkedHooks
        self.warnings = warnings
        self.blockers = blockers
    }
}

/// Protocol for extracting structural features from a host IPA (future macOS/iOS extension).
public protocol HostBinaryFeatureExtractor: Sendable {
    var identifier: String { get }
    func extractFeatures(from host: HostIPAProfile, reader: Zip64Reader) throws -> HostFeatureSet
}

/// Protocol for comparing a new host's features against a known baseline to propose patch locations.
public protocol PatchCandidateLocator: Sendable {
    func locateCandidates(target: HostFeatureSet, baseline: HostFeatureSet) throws -> [PatchCandidate]
}

/// Protocol for verifying that a bridge library (e.g. ABLoginBridge.dylib) fits the target host
/// before passing candidate patch locations to `PatchApplicator`.
public protocol BridgeCompatibilityEvaluator: Sendable {
    func evaluateBridgeCompatibility(
        host: HostFeatureSet,
        candidates: [PatchCandidate],
        kit: VerifiedPatchKit
    ) throws -> BridgeCompatibilityAssessment
}

/// Default v1 feature extractor: emits basic identity features without dynamic scanning.
public struct ExactMatchHostFeatureExtractor: HostBinaryFeatureExtractor {
    public let identifier = "exact-match-v1"

    public init() {}

    public func extractFeatures(from host: HostIPAProfile, reader: Zip64Reader) throws -> HostFeatureSet {
        let features = host.binaries.map { binary in
            HostBinaryFeature(
                binaryPath: binary.path,
                architecture: binary.architectureSummary,
                uuid: binary.primaryUUID
            )
        }
        return HostFeatureSet(
            hostProfile: host,
            binaryFeatures: features,
            extractorIdentifier: identifier
        )
    }
}
