import Foundation
import Zip64Kit

/// Scoped read-only input session shared across Entry 1 (`HostInspector`), Entry 2 (`CompatibilityMatcher` / `IL2CPPAutoResolver`),
/// and Entry 3 (`PatchApplicator`) for a single patch invocation.
/// Keeps a single open `Zip64Reader` file descriptor and caches the decompressed `UnityFramework` buffer so a 200 MB
/// binary is decompressed at most once instead of 3–4 times.
public final class PatchInputSession: @unchecked Sendable {
    public let sourceURL: URL
    public let reader: Zip64Reader

    private let lock = NSLock()
    private var cachedHostProfile: HostIPAProfile?
    private var cachedUnityPath: String?
    private var cachedUnityData: Data?

    public init(ipaURL: URL) throws {
        self.sourceURL = ipaURL
        do {
            self.reader = try Zip64Reader(url: ipaURL)
        } catch let zipErr as ZipError {
            throw PatchError.zipFailure(zipErr)
        }
    }

    public init(reader: Zip64Reader) {
        self.sourceURL = reader.url
        self.reader = reader
    }

    public var hostProfile: HostIPAProfile? {
        lock.lock()
        defer { lock.unlock() }
        return cachedHostProfile
    }

    public func storeHostProfile(_ profile: HostIPAProfile) {
        lock.lock()
        cachedHostProfile = profile
        lock.unlock()
    }

    public func storeUnityFrameworkData(_ data: Data, at path: String) {
        lock.lock()
        cachedUnityPath = path
        cachedUnityData = data
        lock.unlock()
    }

    public func cachedUnityFrameworkData(at path: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard cachedUnityPath == path else { return nil }
        return cachedUnityData
    }

    public func readUnityFrameworkData(at path: String) throws -> Data {
        if let hit = cachedUnityFrameworkData(at: path) {
            return hit
        }
        let data: Data
        do {
            data = try reader.readData(named: path)
        } catch is CancellationError {
            throw CancellationError()
        } catch let zipErr as ZipError {
            throw PatchError.zipFailure(zipErr)
        }
        storeUnityFrameworkData(data, at: path)
        return data
    }

    /// Moves the cached `UnityFramework` buffer out of the session (leaving cache empty) so the caller obtains
    /// unique ownership and can mutate it in place without triggering a ~200 MB copy-on-write duplication.
    public func takeUnityFrameworkData(at path: String) throws -> Data {
        lock.lock()
        let hit: Data?
        if cachedUnityPath == path {
            hit = cachedUnityData
            cachedUnityPath = nil
            cachedUnityData = nil
        } else {
            hit = nil
        }
        lock.unlock()

        if let hit {
            return hit
        }
        do {
            return try reader.readData(named: path)
        } catch is CancellationError {
            throw CancellationError()
        } catch let zipErr as ZipError {
            throw PatchError.zipFailure(zipErr)
        }
    }

    /// Releases the large in-memory `UnityFramework` buffer once binary injection is complete,
    /// keeping peak memory low during streaming ZIP repackaging.
    public func releaseUnityCache() {
        lock.lock()
        cachedUnityPath = nil
        cachedUnityData = nil
        lock.unlock()
    }
}
