import Foundation

public struct HostBinaryInfo: Sendable, Hashable, Codable, Identifiable {
    public var id: String { path }
    public let path: String
    public let slices: [MachOSliceInfo]

    public var isEncrypted: Bool {
        slices.contains(where: \.isEncrypted)
    }

    public var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    public var architectureSummary: String {
        slices.map(\.architectureName).joined(separator: ", ")
    }

    public var primaryUUID: String? {
        slices.first?.uuid
    }

    public init(path: String, slices: [MachOSliceInfo]) {
        self.path = path
        self.slices = slices
    }
}

/// Structured output of Entry 1 (Host Identification).
public struct HostIPAProfile: Sendable, Hashable, Codable {
    public let sourceFileName: String
    public let sourceFileSize: UInt64
    public let appRoot: String
    public let displayName: String
    public let bundleID: String
    public let version: String
    public let build: String
    public let executableName: String
    public let minimumOSVersion: String?
    public let entryCount: Int
    public let binaries: [HostBinaryInfo]
    public let ipaSHA256: String?
    public let il2cppProbe: IL2CPPProbeSummary?

    public var isEncrypted: Bool {
        binaries.contains(where: \.isEncrypted)
    }

    public var encryptedBinaryPaths: [String] {
        binaries.filter(\.isEncrypted).map(\.path)
    }

    public var mainExecutablePath: String {
        appRoot + executableName
    }

    public var mainExecutable: HostBinaryInfo? {
        binaries.first { $0.path == mainExecutablePath }
    }

    public func binary(at path: String) -> HostBinaryInfo? {
        binaries.first { $0.path == path }
    }

    public init(
        sourceFileName: String,
        sourceFileSize: UInt64,
        appRoot: String,
        displayName: String,
        bundleID: String,
        version: String,
        build: String,
        executableName: String,
        minimumOSVersion: String?,
        entryCount: Int,
        binaries: [HostBinaryInfo],
        ipaSHA256: String? = nil,
        il2cppProbe: IL2CPPProbeSummary? = nil
    ) {
        self.sourceFileName = sourceFileName
        self.sourceFileSize = sourceFileSize
        self.appRoot = appRoot
        self.displayName = displayName
        self.bundleID = bundleID
        self.version = version
        self.build = build
        self.executableName = executableName
        self.minimumOSVersion = minimumOSVersion
        self.entryCount = entryCount
        self.binaries = binaries
        self.ipaSHA256 = ipaSHA256
        self.il2cppProbe = il2cppProbe
    }
}
