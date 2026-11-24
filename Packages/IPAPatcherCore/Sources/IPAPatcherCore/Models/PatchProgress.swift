import Foundation

public enum PatchPipelineStage: Int, CaseIterable, Sendable, Hashable, Identifiable {
    case verifyingKit = 0
    case inspectingHost = 1
    case matchingCompatibility = 2
    case preflightValidating = 3
    case repackaging = 4
    case verifyingOutput = 5

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .verifyingKit:
            return "准备补丁组件"
        case .inspectingHost:
            return "读取游戏安装包"
        case .matchingCompatibility:
            return "匹配游戏版本"
        case .preflightValidating:
            return "检查安装包并准备注入"
        case .repackaging:
            return "生成 B 服安装包"
        case .verifyingOutput:
            return "校验成品完整性"
        }
    }
}

public struct PatchProgress: Sendable, Hashable {
    public let stage: PatchPipelineStage
    public let fractionCompleted: Double?
    public let completedEntries: Int?
    public let totalEntries: Int?
    public let processedBytes: UInt64?
    public let totalBytes: UInt64?
    public let detailMessage: String

    public init(
        stage: PatchPipelineStage,
        fractionCompleted: Double? = nil,
        completedEntries: Int? = nil,
        totalEntries: Int? = nil,
        processedBytes: UInt64? = nil,
        totalBytes: UInt64? = nil,
        detailMessage: String
    ) {
        self.stage = stage
        self.fractionCompleted = fractionCompleted
        self.completedEntries = completedEntries
        self.totalEntries = totalEntries
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
        self.detailMessage = detailMessage
    }
}

public struct PatchExecutionResult: Sendable, Hashable, Codable {
    public let outputURL: URL
    public let suggestedExportFilename: String
    public let hostProfile: HostIPAProfile
    public let revision: String
    public let outputBytes: UInt64
    public let preservedSourceFiles: Int
    public let modifiedEntries: [String]
    public let addedEntries: [String]
    public let removedEntries: [String]
    public let zipCRCVerified: Bool
    public let durationSeconds: TimeInterval
    public let adaptationMode: AdaptationMode
    public let appliedCustomBiliIcons: Bool
    public let profileDisplayName: String?
    public let generatedRuntimeProfile: RuntimeOffsetProfile?

    public init(
        outputURL: URL,
        suggestedExportFilename: String,
        hostProfile: HostIPAProfile,
        revision: String,
        outputBytes: UInt64,
        preservedSourceFiles: Int,
        modifiedEntries: [String],
        addedEntries: [String],
        removedEntries: [String],
        zipCRCVerified: Bool,
        durationSeconds: TimeInterval,
        adaptationMode: AdaptationMode = .builtInVerified,
        appliedCustomBiliIcons: Bool = true,
        profileDisplayName: String? = nil,
        generatedRuntimeProfile: RuntimeOffsetProfile? = nil
    ) {
        self.outputURL = outputURL
        self.suggestedExportFilename = suggestedExportFilename
        self.hostProfile = hostProfile
        self.revision = revision
        self.outputBytes = outputBytes
        self.preservedSourceFiles = preservedSourceFiles
        self.modifiedEntries = modifiedEntries
        self.addedEntries = addedEntries
        self.removedEntries = removedEntries
        self.zipCRCVerified = zipCRCVerified
        self.durationSeconds = durationSeconds
        self.adaptationMode = adaptationMode
        self.appliedCustomBiliIcons = appliedCustomBiliIcons
        self.profileDisplayName = profileDisplayName
        self.generatedRuntimeProfile = generatedRuntimeProfile
    }

    enum CodingKeys: String, CodingKey {
        case outputURL
        case suggestedExportFilename
        case hostProfile
        case revision
        case outputBytes
        case preservedSourceFiles
        case modifiedEntries
        case addedEntries
        case removedEntries
        case zipCRCVerified
        case durationSeconds
        case adaptationMode
        case appliedCustomBiliIcons
        case profileDisplayName
        case generatedRuntimeProfile
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.outputURL = try c.decode(URL.self, forKey: .outputURL)
        self.suggestedExportFilename = try c.decode(String.self, forKey: .suggestedExportFilename)
        self.hostProfile = try c.decode(HostIPAProfile.self, forKey: .hostProfile)
        self.revision = try c.decode(String.self, forKey: .revision)
        self.outputBytes = try c.decode(UInt64.self, forKey: .outputBytes)
        self.preservedSourceFiles = try c.decode(Int.self, forKey: .preservedSourceFiles)
        self.modifiedEntries = try c.decode([String].self, forKey: .modifiedEntries)
        self.addedEntries = try c.decode([String].self, forKey: .addedEntries)
        self.removedEntries = try c.decode([String].self, forKey: .removedEntries)
        self.zipCRCVerified = try c.decode(Bool.self, forKey: .zipCRCVerified)
        self.durationSeconds = try c.decode(TimeInterval.self, forKey: .durationSeconds)
        self.adaptationMode = (try? c.decodeIfPresent(AdaptationMode.self, forKey: .adaptationMode)) ?? .builtInVerified
        self.appliedCustomBiliIcons = (try? c.decodeIfPresent(Bool.self, forKey: .appliedCustomBiliIcons)) ?? true
        self.profileDisplayName = try? c.decodeIfPresent(String.self, forKey: .profileDisplayName)
        self.generatedRuntimeProfile = try? c.decodeIfPresent(RuntimeOffsetProfile.self, forKey: .generatedRuntimeProfile)
    }
}
