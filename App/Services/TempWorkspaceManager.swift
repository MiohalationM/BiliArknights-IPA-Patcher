import Foundation
import IPAPatcherCore

struct PendingExportRecord: Sendable, Codable, Equatable {
    let sessionID: String
    let ipaFileName: String
    let exportedFileName: String?
    let result: PatchExecutionResult
    let createdAt: Date
}

/// Manages local storage separation:
/// - Transient working files (`tmp/IPAPatcherSessions/` and `tmp/*-Inbox/`): always auto-cleaned on startup/cancel/failure.
/// - Verified finished outputs (`Application Support/PendingExports/`): excluded from iCloud backup, preserved across
///   background kills (e.g. when user leaves to free disk space after a failed export), and explicitly deletable by the user.
enum TempWorkspaceManager {
    private static let transientSessionsFolder = "IPAPatcherSessions"
    private static let pendingExportsFolder = "PendingExports"
    private static let metadataFileName = "pending-export.json"

    static var transientSessionsRootURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(transientSessionsFolder, isDirectory: true)
    }

    static var pendingExportsRootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(pendingExportsFolder, isDirectory: true)
    }

    // MARK: - Transient Working Sessions (`.partial` & `tmp/*-Inbox`)

    static func createSessionDirectory() throws -> URL {
        let dir = transientSessionsRootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func removeSessionDirectory(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes unfinished `.partial` sessions and stale `tmp/*-Inbox` picker copies without touching verified pending exports.
    static func cleanupTransientJunk() {
        let fm = FileManager.default
        if fm.fileExists(atPath: transientSessionsRootURL.path) {
            try? fm.removeItem(at: transientSessionsRootURL)
        }
        cleanupAllTempInboxDirectories()
    }

    static func cleanupImportedInboxCopyIfNeeded(_ url: URL) {
        let standardized = url.standardizedFileURL.path
        let tmpRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        if standardized.hasPrefix(tmpRoot) && standardized.contains("-Inbox/") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func cleanupAllTempInboxDirectories() {
        let fm = FileManager.default
        let tmpRoot = fm.temporaryDirectory
        guard let items = try? fm.contentsOfDirectory(
            at: tmpRoot,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }

        for item in items where item.lastPathComponent.hasSuffix("-Inbox") {
            try? fm.removeItem(at: item)
        }
    }

    // MARK: - Verified Pending Export Persistence

    /// Atomically promotes a verified finished IPA from transient `tmp/` into `Application Support/PendingExports/`.
    /// Writes the new IPA and its `pending-export.json` record completely BEFORE deleting any previous pending export,
    /// eliminating any data-loss window on mid-write failure or process termination.
    static func promoteVerifiedExport(
        from result: PatchExecutionResult
    ) throws -> PendingExportRecord {
        let fm = FileManager.default
        let root = pendingExportsRootURL
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        excludeFromBackup(root)

        // Snapshot previous session entries BEFORE creating the new session; never remove them until commit succeeds.
        let previousEntries = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []

        let sessionID = UUID().uuidString
        let sessionDir = root.appendingPathComponent(sessionID, isDirectory: true)
        try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        excludeFromBackup(sessionDir)

        let destinationIPA = sessionDir.appendingPathComponent(result.suggestedExportFilename)
        var movedIPA = false
        do {
            try fm.moveItem(at: result.outputURL, to: destinationIPA)
            movedIPA = true
            excludeFromBackup(destinationIPA)

            let updatedResult = PatchExecutionResult(
                outputURL: destinationIPA,
                suggestedExportFilename: result.suggestedExportFilename,
                hostProfile: result.hostProfile,
                revision: result.revision,
                outputBytes: result.outputBytes,
                preservedSourceFiles: result.preservedSourceFiles,
                modifiedEntries: result.modifiedEntries,
                addedEntries: result.addedEntries,
                removedEntries: result.removedEntries,
                zipCRCVerified: result.zipCRCVerified,
                durationSeconds: result.durationSeconds,
                adaptationMode: result.adaptationMode,
                appliedCustomBiliIcons: result.appliedCustomBiliIcons,
                profileDisplayName: result.profileDisplayName
            )

            let record = PendingExportRecord(
                sessionID: sessionID,
                ipaFileName: result.suggestedExportFilename,
                exportedFileName: nil,
                result: updatedResult,
                createdAt: Date()
            )
            // Commit point: atomic write of `pending-export.json` into the new session directory.
            try writeMetadata(record, in: sessionDir)

            // Only AFTER both the new IPA and recovery record are safely on disk, remove superseded sessions.
            for oldEntry in previousEntries where oldEntry.standardizedFileURL != sessionDir.standardizedFileURL {
                try? fm.removeItem(at: oldEntry)
            }
            return record
        } catch {
            if movedIPA, !fm.fileExists(atPath: result.outputURL.path) {
                try? fm.moveItem(at: destinationIPA, to: result.outputURL)
            }
            try? fm.removeItem(at: sessionDir)
            throw error
        }
    }

    static func markPendingExportSaved(
        _ record: PendingExportRecord,
        exportedFileName: String
    ) -> PendingExportRecord {
        let updated = PendingExportRecord(
            sessionID: record.sessionID,
            ipaFileName: record.ipaFileName,
            exportedFileName: exportedFileName,
            result: record.result,
            createdAt: record.createdAt
        )
        let sessionDir = pendingExportsRootURL.appendingPathComponent(record.sessionID, isDirectory: true)
        if FileManager.default.fileExists(atPath: sessionDir.path) {
            try? writeMetadata(updated, in: sessionDir)
        }
        return updated
    }

    /// Restores the newest valid verified finished IPA if the app was terminated in the background,
    /// and safely garbage-collects any incomplete or superseded sibling session directories.
    static func loadPendingExport() -> PendingExportRecord? {
        let fm = FileManager.default
        let root = pendingExportsRootURL
        guard let subdirs = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var validSessions: [(dir: URL, record: PendingExportRecord)] = []
        var staleOrCorruptDirs: [URL] = []

        for dir in subdirs {
            let metaURL = dir.appendingPathComponent(metadataFileName)
            guard let data = try? Data(contentsOf: metaURL),
                  let decoded = try? JSONDecoder().decode(PendingExportRecord.self, from: data) else {
                staleOrCorruptDirs.append(dir)
                continue
            }
            // Re-resolve the IPA URL relative to the current sandbox container path (container UUID can change across reinstalls).
            let resolvedIPA = dir.appendingPathComponent(decoded.ipaFileName)
            guard fm.fileExists(atPath: resolvedIPA.path) else {
                staleOrCorruptDirs.append(dir)
                continue
            }
            let reboundResult = PatchExecutionResult(
                outputURL: resolvedIPA,
                suggestedExportFilename: decoded.result.suggestedExportFilename,
                hostProfile: decoded.result.hostProfile,
                revision: decoded.result.revision,
                outputBytes: decoded.result.outputBytes,
                preservedSourceFiles: decoded.result.preservedSourceFiles,
                modifiedEntries: decoded.result.modifiedEntries,
                addedEntries: decoded.result.addedEntries,
                removedEntries: decoded.result.removedEntries,
                zipCRCVerified: decoded.result.zipCRCVerified,
                durationSeconds: decoded.result.durationSeconds,
                adaptationMode: decoded.result.adaptationMode,
                appliedCustomBiliIcons: decoded.result.appliedCustomBiliIcons,
                profileDisplayName: decoded.result.profileDisplayName
            )
            let reboundRecord = PendingExportRecord(
                sessionID: decoded.sessionID,
                ipaFileName: decoded.ipaFileName,
                exportedFileName: decoded.exportedFileName,
                result: reboundResult,
                createdAt: decoded.createdAt
            )
            validSessions.append((dir: dir, record: reboundRecord))
        }

        // Remove any incomplete/corrupt directories that never finished committing.
        for badDir in staleOrCorruptDirs {
            try? fm.removeItem(at: badDir)
        }

        guard let newest = validSessions.max(by: { $0.record.createdAt < $1.record.createdAt }) else {
            return nil
        }

        // Clean up any older superseded session if a crash happened right after commit and before cleanup.
        for session in validSessions where session.dir.standardizedFileURL != newest.dir.standardizedFileURL {
            try? fm.removeItem(at: session.dir)
        }

        return newest.record
    }

    // MARK: - Explicit Manual Cleanup & Cache Accounting

    static func calculateTotalCacheBytes() -> UInt64 {
        var total: UInt64 = 0
        total &+= directoryAllocatedBytes(at: pendingExportsRootURL)
        total &+= directoryAllocatedBytes(at: transientSessionsRootURL)

        let fm = FileManager.default
        if let tmpItems = try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil) {
            for item in tmpItems where item.lastPathComponent.hasSuffix("-Inbox") {
                total &+= directoryAllocatedBytes(at: item)
            }
        }
        return total
    }

    /// Manually deletes ALL local cached outputs, transient sessions, and temp Inbox files, returning freed bytes.
    @discardableResult
    static func deleteAllLocalCache() -> UInt64 {
        let before = calculateTotalCacheBytes()
        let fm = FileManager.default
        if fm.fileExists(atPath: pendingExportsRootURL.path) {
            try? fm.removeItem(at: pendingExportsRootURL)
        }
        cleanupTransientJunk()
        return before
    }

    // MARK: - Helpers

    private static func writeMetadata(_ record: PendingExportRecord, in dir: URL) throws {
        let metaURL = dir.appendingPathComponent(metadataFileName)
        let data = try JSONEncoder().encode(record)
        try data.write(to: metaURL, options: [.atomic])
        excludeFromBackup(metaURL)
    }

    private static func excludeFromBackup(_ url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }

    private static func directoryAllocatedBytes(at url: URL) -> UInt64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        var total: UInt64 = 0
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return 0
        }
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  size > 0 else {
                continue
            }
            total &+= UInt64(size)
        }
        return total
    }
}
