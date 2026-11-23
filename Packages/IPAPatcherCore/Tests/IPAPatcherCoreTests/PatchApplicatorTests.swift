import CryptoKit
import Foundation
import XCTest
@testable import IPAPatcherCore
import Zip64Kit

final class PatchApplicatorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatchApplicatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testEndToEndDynamicInjectionCarrierKitAndBaselineUnityParity() throws {
        let engine = try IPAPatcherEngine.builtInDefault()
        let kits = try engine.verifyConfiguredKits()
        let manifest = kits[0].manifest

        let inputIPA = tempDir.appendingPathComponent("arknights-2.7.91-synthetic.ipa")
        try SyntheticIPABuilder.createSyntheticIPA(at: inputIPA, manifest: manifest)
        let originalInputSHA = try FileHasher.sha256Hex(of: inputIPA)

        let host = try engine.inspectHost(at: inputIPA)
        let matchResult = try engine.matchCompatibility(for: host, verifiedKits: kits)
        guard case .matched(let config) = matchResult else {
            return XCTFail("Synthetic IPA should match built-in carrier kit")
        }

        let swiftOutDir = tempDir.appendingPathComponent("swift-out", isDirectory: true)
        let result = try engine.applyPatch(
            configuration: config,
            sourceIPAURL: inputIPA,
            workingDirectory: swiftOutDir
        )

        // Original IPA untouched and zero `.partial` files left behind.
        XCTAssertEqual(try FileHasher.sha256Hex(of: inputIPA), originalInputSHA)
        let swiftDirContents = try FileManager.default.contentsOfDirectory(atPath: swiftOutDir.path)
        XCTAssertEqual(swiftDirContents, [result.suggestedExportFilename])
        XCTAssertTrue(result.zipCRCVerified)
        // Older pending exports carried a whole-IPA digest. Keep them restorable after its removal.
        let resultJSON = try JSONEncoder().encode(result)
        var legacyRecord = try XCTUnwrap(JSONSerialization.jsonObject(with: resultJSON) as? [String: Any])
        XCTAssertNil(legacyRecord["outputSHA256"])
        legacyRecord["outputSHA256"] = try FileHasher.sha256Hex(of: result.outputURL)
        let legacyJSON = try JSONSerialization.data(withJSONObject: legacyRecord)
        XCTAssertEqual(try JSONDecoder().decode(PatchExecutionResult.self, from: legacyJSON), result)
        XCTAssertEqual(result.removedEntries.count, 4)
        XCTAssertTrue(result.addedEntries.contains("Payload/Arknights.app/Frameworks/ABLoginBridge.dylib"))
        XCTAssertTrue(result.addedEntries.contains("Payload/Arknights.app/Frameworks/ABSDKCarrier.dylib"))
        XCTAssertTrue(result.addedEntries.contains("Payload/Arknights.app/ABRuntimeProfile.plist"))

        let swiftReader = try Zip64Reader(url: result.outputURL)

        // Verify both added dylibs have executable Unix permissions `0o100755`.
        for dylib in [
            "Payload/Arknights.app/Frameworks/ABLoginBridge.dylib",
            "Payload/Arknights.app/Frameworks/ABSDKCarrier.dylib"
        ] {
            let entry = try XCTUnwrap(swiftReader.entry(named: dylib))
            XCTAssertEqual(entry.externalFileAttributes >> 16, 0o100755)
        }

        // Verify dynamically merged Info.plist preserved host keys & updated U8SDK to Bilibili.
        let patchedPlistData = try swiftReader.readData(named: "Payload/Arknights.app/Info.plist")
        let plistObj = try PropertyListSerialization.propertyList(from: patchedPlistData, options: [], format: nil)
        let plist = try XCTUnwrap(plistObj as? [String: Any])
        XCTAssertEqual(plist["ABPackagingRevision"] as? String, "7.5-2.7.91-bridge-carrier-r4")
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "2.7.91")
        let u8 = try XCTUnwrap(plist["U8SDK"] as? [String: Any])
        XCTAssertEqual(u8["Channel"] as? Int, 2)
        XCTAssertEqual(u8["World"] as? Int, 2)
        XCTAssertEqual(u8["ChannelName"] as? String, "HG")

        // Cross-check patched UnityFramework byte-for-byte against baseline `dist/patch.py`!
        let baselineScript = "/Users/mio/biios/reverse/bridge-2.7.91/dist/patch.py"
        if FileManager.default.fileExists(atPath: baselineScript),
           let python311 = Self.findPython311Plus() {
            let pyOutIPA = tempDir.appendingPathComponent("python-out.ipa")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: python311)
            proc.arguments = [baselineScript, "patch", inputIPA.path, "--output", pyOutIPA.path]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                let msg = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                XCTFail("Baseline patch.py failed: \(msg)")
            }

            let pyReader = try Zip64Reader(url: pyOutIPA)
            let unityPath = "Payload/Arknights.app/Frameworks/UnityFramework.framework/UnityFramework"
            XCTAssertEqual(try swiftReader.readData(named: unityPath), try pyReader.readData(named: unityPath))
        }
    }

    func testRejectsAlreadyInjectedIPABeforeWritingOutput() throws {
        let engine = try IPAPatcherEngine.builtInDefault()
        let kits = try engine.verifyConfiguredKits()
        let manifest = kits[0].manifest

        var cfg = SyntheticIPABuilder.Configuration()
        cfg.preInjectBridge = true
        let alreadyPatchedIPA = tempDir.appendingPathComponent("already-injected.ipa")
        try SyntheticIPABuilder.createSyntheticIPA(at: alreadyPatchedIPA, manifest: manifest, config: cfg)

        let host = try engine.inspectHost(at: alreadyPatchedIPA)
        XCTAssertEqual(host.il2cppProbe?.detectedInjectedBridge, true)

        let matchResult = try engine.matchCompatibility(for: host, verifiedKits: kits)
        guard case .matched(let config) = matchResult else {
            return XCTFail("Metadata matches; alreadyInjected check must trigger in Entry 3 preflight")
        }

        let outDir = tempDir.appendingPathComponent("no-output-dir", isDirectory: true)
        XCTAssertThrowsError(
            try engine.applyPatch(configuration: config, sourceIPAURL: alreadyPatchedIPA, workingDirectory: outDir)
        ) { error in
            guard case PatchError.alreadyInjected = error else {
                return XCTFail("Expected alreadyInjected, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outDir.path))
    }

    func testRejectsNonZeroHeaderGapBeforeWritingOutput() throws {
        let engine = try IPAPatcherEngine.builtInDefault()
        let kits = try engine.verifyConfiguredKits()
        let manifest = kits[0].manifest

        var cfg = SyntheticIPABuilder.Configuration()
        cfg.corruptPreimage = true
        let badGapIPA = tempDir.appendingPathComponent("dirty-gap.ipa")
        try SyntheticIPABuilder.createSyntheticIPA(at: badGapIPA, manifest: manifest, config: cfg)

        let host = try engine.inspectHost(at: badGapIPA)
        let matchResult = try engine.matchCompatibility(for: host, verifiedKits: kits)
        guard case .matched(let config) = matchResult else {
            return XCTFail("Metadata matches; header gap check must trigger in Entry 3 preflight")
        }

        let outDir = tempDir.appendingPathComponent("no-output-gap", isDirectory: true)
        XCTAssertThrowsError(
            try engine.applyPatch(configuration: config, sourceIPAURL: badGapIPA, workingDirectory: outDir)
        ) { error in
            guard case PatchError.machOInjectionFailed = error else {
                return XCTFail("Expected machOInjectionFailed, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outDir.path))
    }

    func testCancellationCleansUpPartialFile() async throws {
        let engine = try IPAPatcherEngine.builtInDefault()
        let kits = try engine.verifyConfiguredKits()
        let manifest = kits[0].manifest

        var cfg = SyntheticIPABuilder.Configuration()
        cfg.extraResourceBytes = 4 * 1024 * 1024
        let inputIPA = tempDir.appendingPathComponent("cancel-input.ipa")
        try SyntheticIPABuilder.createSyntheticIPA(at: inputIPA, manifest: manifest, config: cfg)

        let host = try engine.inspectHost(at: inputIPA)
        let matchResult = try engine.matchCompatibility(for: host, verifiedKits: kits)
        guard case .matched(let config) = matchResult else {
            return XCTFail("Expected match")
        }

        let outDir = tempDir.appendingPathComponent("cancel-out", isDirectory: true)
        let taskBox = TaskBox()
        let task = Task.detached {
            try engine.applyPatch(configuration: config, sourceIPAURL: inputIPA, workingDirectory: outDir) { progress in
                if progress.stage == .repackaging {
                    taskBox.cancel()
                }
            }
        }
        taskBox.setTask(task)

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        }

        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []
        XCTAssertTrue(leftover.isEmpty, "Expected all partial files cleaned up, found: \(leftover)")
    }

    private static func findPython311Plus() -> String? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3.13",
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11",
            "/usr/bin/python3"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = ["-c", "import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)"]
            if (try? proc.run()) != nil {
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    return path
                }
            }
        }
        return nil
    }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<PatchExecutionResult, Error>?

    func setTask(_ t: Task<PatchExecutionResult, Error>) {
        lock.lock()
        task = t
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        task?.cancel()
        lock.unlock()
    }
}
