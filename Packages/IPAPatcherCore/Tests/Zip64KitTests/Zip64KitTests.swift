import Foundation
import XCTest
@testable import Zip64Kit

final class Zip64KitTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Zip64KitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testRoundTripStandardAndZip64WithChunkedStreaming() throws {
        let zipURL = tempDir.appendingPathComponent("forced-zip64.zip")
        // 512 KB pseudo-random + repetitive payload to exercise multi-chunk streaming.
        var largeData = Data(capacity: 512 * 1024)
        for i in 0..<(512 * 1024) {
            largeData.append(UInt8((i &* 31 &+ (i >> 7)) & 0xFF))
        }
        let textData = Data("你好，明日方舟 ZIP64 校验测试！\n".utf8)

        let writer = try Zip64Writer(url: zipURL, forceZip64: true)
        try writer.writeDirectoryEntry(name: "Payload/")
        try writer.writeDeflatedEntry(
            name: "Payload/hello.txt",
            data: textData,
            externalAttributes: 0o100644 << 16,
            chunkSize: 64 * 1024
        )
        try writer.writeDeflatedEntry(
            name: "Payload/large.bin",
            data: largeData,
            externalAttributes: 0o100755 << 16,
            chunkSize: 64 * 1024
        )
        try writer.finish()

        // Verify our Zip64Reader reads everything accurately.
        let reader = try Zip64Reader(url: zipURL)
        XCTAssertEqual(reader.entryNames, ["Payload/", "Payload/hello.txt", "Payload/large.bin"])
        XCTAssertEqual(try reader.readData(named: "Payload/hello.txt"), textData)
        XCTAssertEqual(try reader.readData(named: "Payload/large.bin"), largeData)
        try reader.verifyAllEntriesCRC()

        // Test raw compressed copy into a second archive.
        let copyURL = tempDir.appendingPathComponent("copied.zip")
        let copyWriter = try Zip64Writer(url: copyURL)
        for entry in reader.entries {
            if entry.isDirectory {
                try copyWriter.writeDirectoryEntry(
                    name: entry.name,
                    versionMadeBy: entry.versionMadeBy,
                    externalAttributes: entry.externalFileAttributes,
                    dosTime: entry.dosTime,
                    dosDate: entry.dosDate
                )
            } else {
                try copyWriter.copyRawEntry(from: reader, entry: entry, chunkSize: 64 * 1024)
            }
        }
        try copyWriter.finish()

        let copyReader = try Zip64Reader(url: copyURL)
        XCTAssertEqual(try copyReader.readData(named: "Payload/large.bin"), largeData)
        try copyReader.verifyAllEntriesCRC()

        // Cross-check with macOS `unzip -t` and Python `zipfile`.
        try runProcess("/usr/bin/unzip", args: ["-t", zipURL.path])
        try runProcess("/usr/bin/unzip", args: ["-t", copyURL.path])
        try runProcess(
            "/usr/bin/python3",
            args: [
                "-c",
                "import zipfile, sys; z=zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None; assert len(z.namelist())==3",
                zipURL.path
            ]
        )
    }

    func testRejectsUnsafePathsAndDuplicates() throws {
        XCTAssertThrowsError(try ZipPathValidator.validateSinglePath("../escape.txt")) { err in
            XCTAssertEqual(err as? ZipError, .unsafeEntryPath("../escape.txt"))
        }
        XCTAssertThrowsError(try ZipPathValidator.validateSinglePath("/absolute/path")) { err in
            XCTAssertEqual(err as? ZipError, .unsafeEntryPath("/absolute/path"))
        }
        XCTAssertThrowsError(try ZipPathValidator.validateSinglePath("Payload\\bad.txt")) { err in
            XCTAssertEqual(err as? ZipError, .unsafeEntryPath("Payload\\bad.txt"))
        }
        XCTAssertThrowsError(try ZipPathValidator.validateSinglePath("Payload/a:b.txt")) { err in
            XCTAssertEqual(err as? ZipError, .unsafeEntryPath("Payload/a:b.txt"))
        }
        XCTAssertThrowsError(try ZipPathValidator.validate(names: ["a.txt", "b.txt", "a.txt"])) { err in
            XCTAssertEqual(err as? ZipError, .duplicateEntry("a.txt"))
        }

        // Build a ZIP with duplicate entry names using Python zipfile to ensure Zip64Reader rejects it on open.
        let dupZipURL = tempDir.appendingPathComponent("dup.zip")
        try runProcess(
            "/usr/bin/python3",
            args: [
                "-c",
                """
                import zipfile, sys
                with zipfile.ZipFile(sys.argv[1], 'w') as z:
                    z.writestr('Payload/a.txt', b'1')
                    z.writestr('Payload/a.txt', b'2')
                """,
                dupZipURL.path
            ]
        )
        XCTAssertThrowsError(try Zip64Reader(url: dupZipURL)) { err in
            XCTAssertEqual(err as? ZipError, .duplicateEntry("Payload/a.txt"))
        }
    }

    func testDetectsCorruptedPayloadCRC() throws {
        let zipURL = tempDir.appendingPathComponent("corrupt.zip")
        let writer = try Zip64Writer(url: zipURL)
        let original = Data(repeating: 0x41, count: 4096)
        try writer.writeDeflatedEntry(
            name: "Payload/data.bin",
            data: original,
            externalAttributes: 0o100644 << 16
        )
        try writer.finish()

        // Flip a byte inside the compressed payload area.
        var fileBytes = try Data(contentsOf: zipURL)
        let readerBefore = try Zip64Reader(url: zipURL)
        let dataOffset = try readerBefore.localDataOffset(for: readerBefore.entries[0])
        fileBytes[Int(dataOffset) + 2] ^= 0xFF
        try fileBytes.write(to: zipURL)

        let readerAfter = try Zip64Reader(url: zipURL)
        XCTAssertThrowsError(try readerAfter.verifyAllEntriesCRC())
    }

    func testCorruptedZip64OverflowOffsetAndOversizedInflateReturnCleanErrors() throws {
        // 1. ZIP64 EOCD Locator with `zip64EOCDOffset = UInt64.max` must NOT crash with integer overflow!
        let zip64URL = tempDir.appendingPathComponent("overflow-z64.zip")
        let writer = try Zip64Writer(url: zip64URL, forceZip64: true)
        try writer.writeDeflatedEntry(
            name: "Payload/a.txt",
            data: Data("hello".utf8),
            externalAttributes: 0o100644 << 16
        )
        try writer.finish()

        var bytes = try Data(contentsOf: zip64URL)
        // ZIP64 EOCD Locator sits 20 bytes before the 22-byte EOCD at the end of the archive.
        let locatorStart = bytes.count - 22 - 20
        // Offset +8..+15 inside locator is `zip64EOCDOffset`; overwrite with 0xFFFFFFFFFFFFFFFF.
        bytes.replaceSubrange((locatorStart + 8)..<(locatorStart + 16), with: Data(repeating: 0xFF, count: 8))
        try bytes.write(to: zip64URL)

        XCTAssertThrowsError(try Zip64Reader(url: zip64URL)) { err in
            guard case ZipError.truncatedArchive = err else {
                return XCTFail("Expected ZipError.truncatedArchive, got \(err)")
            }
        }

        // 2. Deflated entry whose actual inflated bytes exceed declared `uncompressedSize` must stop immediately.
        let bombURL = tempDir.appendingPathComponent("oversized-inflate.zip")
        let bombWriter = try Zip64Writer(url: bombURL)
        let actualPayload = Data(repeating: 0x42, count: 128 * 1024)
        try bombWriter.writeDeflatedEntry(
            name: "Payload/big.bin",
            data: actualPayload,
            externalAttributes: 0o100644 << 16,
            chunkSize: 16 * 1024
        )
        try bombWriter.finish()

        var bombBytes = try Data(contentsOf: bombURL)
        // Patch the central directory entry's declared uncompressedSize (offset +24 in CD record) down to 100 bytes.
        let cdSig = Data([0x50, 0x4B, 0x01, 0x02])
        let cdRange = try XCTUnwrap(bombBytes.range(of: cdSig))
        let uncompPos = cdRange.lowerBound + 24
        var fakeSize = UInt32(100).littleEndian
        withUnsafeBytes(of: &fakeSize) { bombBytes.replaceSubrange(uncompPos..<(uncompPos + 4), with: $0) }
        try bombBytes.write(to: bombURL)

        let bombReader = try Zip64Reader(url: bombURL)
        var callbackBytes = 0
        XCTAssertThrowsError(
            try bombReader.streamDecompressed(entry: bombReader.entries[0], chunkSize: 64 * 1024) { chunk in
                callbackBytes += chunk.count
            }
        ) { err in
            guard case ZipError.sizeMismatch = err else {
                return XCTFail("Expected ZipError.sizeMismatch, got \(err)")
            }
        }
        XCTAssertEqual(callbackBytes, 0, "Callback must never receive chunks exceeding declared uncompressedSize")
    }

    private func runProcess(_ launchPath: String, args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTFail("Command \(launchPath) \(args.joined(separator: " ")) failed (\(proc.terminationStatus)): \(output)")
        }
    }
}
