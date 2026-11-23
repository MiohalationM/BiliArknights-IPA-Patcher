import CryptoKit
import Foundation
import Zip64Kit

public struct HostInspectionOptions: Sendable, Hashable {
    public let includeBinarySHA256: Bool
    public let includeIPASHA256: Bool

    public static let `default` = HostInspectionOptions(includeBinarySHA256: false, includeIPASHA256: false)
    public static let fullWithHashes = HostInspectionOptions(includeBinarySHA256: true, includeIPASHA256: true)

    public init(includeBinarySHA256: Bool = false, includeIPASHA256: Bool = false) {
        self.includeBinarySHA256 = includeBinarySHA256
        self.includeIPASHA256 = includeIPASHA256
    }
}

/// Entry 1: Host IPA Identification.
/// Reads an IPA archive and extracts structured bundle metadata, discovered executables,
/// Mach-O architectures, UUIDs, and encryption state without coupling to UI.
public struct HostInspector: Sendable {
    public init() {}

    public func inspect(
        ipaURL: URL,
        options: HostInspectionOptions = .default,
        onProgress: (@Sendable (PatchProgress) -> Void)? = nil
    ) throws -> HostIPAProfile {
        try Task.checkCancellation()
        onProgress?(
            PatchProgress(
                stage: .inspectingHost,
                fractionCompleted: 0.05,
                detailMessage: "正在读取 IPA 目录并校验 ZIP 条目安全性…"
            )
        )

        let session = try PatchInputSession(ipaURL: ipaURL)
        return try inspect(session: session, options: options, onProgress: onProgress)
    }

    public func inspect(
        session: PatchInputSession,
        options: HostInspectionOptions = .default,
        onProgress: (@Sendable (PatchProgress) -> Void)? = nil
    ) throws -> HostIPAProfile {
        let profile = try inspect(
            reader: session.reader,
            options: options,
            cacheUnityData: { path, data in
                session.storeUnityFrameworkData(data, at: path)
            },
            onProgress: onProgress
        )
        session.storeHostProfile(profile)
        return profile
    }

    public func inspect(
        reader: Zip64Reader,
        options: HostInspectionOptions = .default,
        onProgress: (@Sendable (PatchProgress) -> Void)? = nil
    ) throws -> HostIPAProfile {
        try inspect(reader: reader, options: options, cacheUnityData: nil, onProgress: onProgress)
    }

    private func inspect(
        reader: Zip64Reader,
        options: HostInspectionOptions,
        cacheUnityData: ((String, Data) -> Void)?,
        onProgress: (@Sendable (PatchProgress) -> Void)?
    ) throws -> HostIPAProfile {
        try Task.checkCancellation()
        let names = reader.entryNames

        // Match Python `inspect_ipa`: exactly one top-level `Payload/<Name>.app/Info.plist`.
        let mainPlists = names.filter { name in
            guard name.hasPrefix("Payload/"), name.hasSuffix(".app/Info.plist") else {
                return false
            }
            let slashCount = name.reduce(into: 0) { count, ch in
                if ch == "/" { count += 1 }
            }
            return slashCount == 2
        }

        guard mainPlists.count == 1, let mainPlistPath = mainPlists.first else {
            throw PatchError.missingAppBundle(foundCount: mainPlists.count)
        }

        let appRoot = String(mainPlistPath.dropLast("Info.plist".count))
        let plistData: Data
        do {
            plistData = try reader.readData(named: mainPlistPath)
        } catch let zipError as ZipError {
            throw PatchError.zipFailure(zipError)
        }

        let infoDict = try parsePlistDictionary(plistData, path: mainPlistPath)
        guard let executableName = stringValue(infoDict["CFBundleExecutable"]), !executableName.isEmpty else {
            throw PatchError.invalidInfoPlist("缺少 CFBundleExecutable 字段")
        }

        let bundleID = stringValue(infoDict["CFBundleIdentifier"]) ?? ""
        let version = stringValue(infoDict["CFBundleShortVersionString"]) ?? ""
        let build = stringValue(infoDict["CFBundleVersion"]) ?? ""
        let displayName = stringValue(infoDict["CFBundleDisplayName"])
            ?? stringValue(infoDict["CFBundleName"])
            ?? executableName
        let minimumOSVersion = stringValue(infoDict["MinimumOSVersion"])

        // Discover all executable binaries matching `patch.py`'s discovery rules.
        var binaryPaths = Set<String>()
        binaryPaths.insert(appRoot + executableName)

        for name in names {
            try Task.checkCancellation()
            if name.hasPrefix(appRoot) && name.hasSuffix("/Info.plist")
                && (name.contains(".framework/") || name.contains(".appex/")) {
                let nestedData: Data
                do {
                    nestedData = try reader.readData(named: name)
                } catch let zipError as ZipError {
                    throw PatchError.zipFailure(zipError)
                }
                let nestedInfo = try parsePlistDictionary(nestedData, path: name)
                if let nestedExec = stringValue(nestedInfo["CFBundleExecutable"]), !nestedExec.isEmpty {
                    let parentDir = String(name.dropLast("Info.plist".count))
                    binaryPaths.insert(parentDir + nestedExec)
                }
            }
            if name.hasPrefix(appRoot + "Frameworks/") && name.hasSuffix(".dylib") {
                binaryPaths.insert(name)
            }
        }

        let sortedPaths = binaryPaths.sorted()
        var binaries: [HostBinaryInfo] = []
        binaries.reserveCapacity(sortedPaths.count)
        var il2cppProbe: IL2CPPProbeSummary?

        for (index, binaryPath) in sortedPaths.enumerated() {
            try Task.checkCancellation()
            let fraction = 0.15 + 0.80 * (Double(index) / Double(max(1, sortedPaths.count)))
            let binaryName = URL(fileURLWithPath: binaryPath).lastPathComponent
            onProgress?(
                PatchProgress(
                    stage: .inspectingHost,
                    fractionCompleted: fraction,
                    completedEntries: index,
                    totalEntries: sortedPaths.count,
                    detailMessage: "正在解析二进制（\(index + 1)/\(sortedPaths.count)）：\(binaryName)"
                )
            )

            guard let entry = reader.entry(named: binaryPath) else {
                throw PatchError.missingExecutable(binaryPath)
            }
            let binaryData: Data
            do {
                binaryData = try reader.readData(for: entry)
            } catch let zipError as ZipError {
                throw PatchError.zipFailure(zipError)
            }

            if binaryPath.hasSuffix("UnityFramework.framework/UnityFramework") {
                cacheUnityData?(binaryPath, binaryData)
                il2cppProbe = IL2CPPProbe.inspect(
                    reader: reader,
                    appRoot: appRoot,
                    unityBinaryData: binaryData
                )
            }

            let slices = try MachOParser.parseSlices(
                data: binaryData,
                binaryPath: binaryPath,
                includeSHA256: options.includeBinarySHA256
            )
            binaries.append(HostBinaryInfo(path: binaryPath, slices: slices))
        }

        if il2cppProbe == nil {
            il2cppProbe = IL2CPPProbe.inspect(reader: reader, appRoot: appRoot, unityBinaryData: nil)
        }

        let ipaSHA256: String?
        if options.includeIPASHA256 {
            ipaSHA256 = try FileHasher.sha256Hex(of: reader.url)
        } else {
            ipaSHA256 = nil
        }

        onProgress?(
            PatchProgress(
                stage: .inspectingHost,
                fractionCompleted: 1.0,
                completedEntries: sortedPaths.count,
                totalEntries: sortedPaths.count,
                detailMessage: "宿主识别完成：\(displayName) \(version) (build \(build))"
            )
        )

        return HostIPAProfile(
            sourceFileName: reader.url.lastPathComponent,
            sourceFileSize: reader.fileSize,
            appRoot: appRoot,
            displayName: displayName,
            bundleID: bundleID,
            version: version,
            build: build,
            executableName: executableName,
            minimumOSVersion: minimumOSVersion,
            entryCount: reader.entries.count,
            binaries: binaries,
            ipaSHA256: ipaSHA256,
            il2cppProbe: il2cppProbe
        )
    }

    private func parsePlistDictionary(_ data: Data, path: String) throws -> [String: Any] {
        do {
            let obj = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard let dict = obj as? [String: Any] else {
                throw PatchError.invalidInfoPlist("\(path) 顶层不是字典结构")
            }
            return dict
        } catch let patchErr as PatchError {
            throw patchErr
        } catch {
            throw PatchError.invalidInfoPlist("\(path)：\(error.localizedDescription)")
        }
    }

    private func stringValue(_ raw: Any?) -> String? {
        switch raw {
        case let str as String:
            return str
        case let num as NSNumber:
            return num.stringValue
        default:
            return nil
        }
    }
}

public enum FileHasher {
    public static func sha256Hex(of url: URL, chunkSize: Int = 2 * 1024 * 1024) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw PatchError.ioFailure("无法打开文件计算哈希：\(url.lastPathComponent)（\(error.localizedDescription)）")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                throw PatchError.ioFailure("读取文件计算哈希失败：\(error.localizedDescription)")
            }
            guard let data = chunk, !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().hexString
    }
}
