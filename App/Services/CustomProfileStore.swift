import CryptoKit
import Foundation
import IPAPatcherCore

/// Persists user-imported manual adaptation profiles (`RuntimeOffsetProfile`) inside
/// `Application Support/CustomProfiles/` (excluded from iCloud backup) so future game updates
/// can be adapted by importing a tiny `.json` or `.plist` file without updating or reinstalling the App.
enum CustomProfileStore {
    private static let folderName = "CustomProfiles"
    private static let maxProfileBytes = 2 * 1024 * 1024

    static var rootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Generates a deterministic, collision-free filename from the full `(bundleID, version, build, unityUUID)` key.
    static func storageFilename(for profile: RuntimeOffsetProfile) -> String {
        let key = "\(profile.bundleID.lowercased())|\(profile.version)|\(profile.build)|\(profile.unityUUID.lowercased())"
        let digest = SHA256.hash(data: Data(key.utf8)).hexString.prefix(16)
        let safeVer = PatchApplicator.sanitizeFilenameToken(profile.version, fallback: "v").prefix(12)
        let safeBuild = PatchApplicator.sanitizeFilenameToken(profile.build, fallback: "0").prefix(8)
        return "profile-\(safeVer)-b\(safeBuild)-\(digest).json"
    }

    static func loadAll() -> [RuntimeOffsetProfile] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var profiles: [RuntimeOffsetProfile] = []
        for file in files where file.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: file),
                  let profile = try? decoder.decode(RuntimeOffsetProfile.self, from: data) else {
                continue
            }
            profiles.append(profile)
        }

        return profiles.sorted { lhs, rhs in
            let lDate = lhs.importedAt ?? .distantPast
            let rDate = rhs.importedAt ?? .distantPast
            if lDate != rDate { return lDate > rDate }
            return lhs.version > rhs.version
        }
    }

    /// Reads, validates, and saves an imported `.json` or `.plist` adaptation profile.
    static func importProfile(from sourceURL: URL) throws -> RuntimeOffsetProfile {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
            TempWorkspaceManager.cleanupImportedInboxCopyIfNeeded(sourceURL)
        }

        // Check file size BEFORE reading into memory so selecting a multi-GB IPA by mistake never spikes RAM.
        if let fileSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
           fileSize > maxProfileBytes {
            throw PatchError.invalidCustomProfile("配置文件体积过大（超过 2 MB），请确认选择的是 .json 或 .plist 适配配置文件。")
        }

        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            throw PatchError.fileAccessDenied("无法读取配置文件：\(error.localizedDescription)")
        }

        guard data.count <= maxProfileBytes else {
            throw PatchError.invalidCustomProfile("配置文件体积过大（超过 2 MB），请确认选择的是 .json 或 .plist 适配配置文件。")
        }

        let parsed = try RuntimeOffsetProfile.decode(from: data)
        let stamped = parsed.withImportedTimestamp(Date())
        try save(stamped)
        return stamped
    }

    static func save(_ profile: RuntimeOffsetProfile) throws {
        try profile.validate()
        let fm = FileManager.default
        let root = rootURL
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        excludeFromBackup(root)

        let destURL = root.appendingPathComponent(storageFilename(for: profile))

        // Discover any superseded files targeting the exact same (bundleID, version, build, unityUUID)
        // BEFORE writing, but delete them ONLY AFTER the new file is atomically committed on disk.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let existingFiles = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var supersededFiles: [URL] = []
        for file in existingFiles where file.pathExtension.lowercased() == "json"
            && file.standardizedFileURL != destURL.standardizedFileURL {
            if let data = try? Data(contentsOf: file),
               let existing = try? decoder.decode(RuntimeOffsetProfile.self, from: data),
               existing.bundleID == profile.bundleID,
               existing.version == profile.version,
               existing.build == profile.build,
               existing.unityUUID.lowercased() == profile.unityUUID.lowercased() {
                supersededFiles.append(file)
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profile)

        try data.write(to: destURL, options: [.atomic])
        excludeFromBackup(destURL)

        for oldFile in supersededFiles {
            try? fm.removeItem(at: oldFile)
        }
    }

    static func delete(profileID: String) throws {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files where file.pathExtension.lowercased() == "json" {
            if let data = try? Data(contentsOf: file),
               let p = try? decoder.decode(RuntimeOffsetProfile.self, from: data),
               p.id == profileID {
                try fm.removeItem(at: file)
            }
        }
    }

    private static func excludeFromBackup(_ url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }
}
