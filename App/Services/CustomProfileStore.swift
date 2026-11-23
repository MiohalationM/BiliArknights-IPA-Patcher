import Foundation
import IPAPatcherCore

/// Persists user-imported manual adaptation profiles (`RuntimeOffsetProfile`) inside
/// `Application Support/CustomProfiles/` (excluded from iCloud backup) so future game updates
/// can be adapted by importing a tiny `.json` or `.plist` file without updating or reinstalling the App.
enum CustomProfileStore {
    private static let folderName = "CustomProfiles"

    static var rootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(folderName, isDirectory: true)
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

        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            throw PatchError.fileAccessDenied("无法读取配置文件：\(error.localizedDescription)")
        }

        guard data.count <= 2 * 1024 * 1024 else {
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

        // Replace any previous profile targeting the exact same (version, build, unityUUID).
        for existing in loadAll() where existing.version == profile.version
            && existing.build == profile.build
            && existing.unityUUID.lowercased() == profile.unityUUID.lowercased() {
            try? delete(profileID: existing.id)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profile)

        let safeName = sanitizedFilename(profile.id) + ".json"
        let destURL = root.appendingPathComponent(safeName)
        try data.write(to: destURL, options: [.atomic])
        excludeFromBackup(destURL)
    }

    static func delete(profileID: String) throws {
        let fm = FileManager.default
        let safeName = sanitizedFilename(profileID) + ".json"
        let directURL = rootURL.appendingPathComponent(safeName)
        if fm.fileExists(atPath: directURL.path) {
            try fm.removeItem(at: directURL)
            return
        }

        // Fallback scan in case filename differed.
        guard let files = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files {
            if let data = try? Data(contentsOf: file),
               let p = try? decoder.decode(RuntimeOffsetProfile.self, from: data),
               p.id == profileID {
                try fm.removeItem(at: file)
            }
        }
    }

    private static func sanitizedFilename(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let str = String(cleaned)
        return str.isEmpty ? UUID().uuidString : str
    }

    private static func excludeFromBackup(_ url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }
}
