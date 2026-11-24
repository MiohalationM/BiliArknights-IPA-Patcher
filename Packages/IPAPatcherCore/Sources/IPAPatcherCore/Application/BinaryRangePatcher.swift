import CryptoKit
import Foundation

/// Applies verified byte-range patches to host Mach-O binaries, strictly validating every preimage byte
/// and optional whole-binary `before_sha256` / `after_sha256` digests.
public enum BinaryRangePatcher {
    public static func apply(
        raw: Data,
        spec: PatchKitManifest.BinaryPatchSpec,
        binaryPath: String
    ) throws -> Data {
        if let expectedBefore = spec.beforeSHA256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !expectedBefore.isEmpty {
            let actualBefore = SHA256.hash(data: raw).hexString
            guard actualBefore == expectedBefore else {
                throw PatchError.preimageMismatch(binaryPath: binaryPath, offset: 0)
            }
        }

        var edited = raw

        for change in spec.ranges {
            let before = try decodeHex(change.before, binaryPath: binaryPath, offset: change.offset)
            let after = try decodeHex(change.after, binaryPath: binaryPath, offset: change.offset)

            guard change.offset >= 0,
                  before.count == after.count,
                  change.offset + before.count <= raw.count else {
                throw PatchError.preimageMismatch(binaryPath: binaryPath, offset: change.offset)
            }

            let start = raw.startIndex + change.offset
            let end = start + before.count
            guard raw[start..<end] == before else {
                throw PatchError.preimageMismatch(binaryPath: binaryPath, offset: change.offset)
            }

            let editStart = edited.startIndex + change.offset
            edited.replaceSubrange(editStart..<(editStart + after.count), with: after)
        }

        if let expectedAfter = spec.afterSHA256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !expectedAfter.isEmpty {
            let actualAfter = SHA256.hash(data: edited).hexString
            guard actualAfter == expectedAfter else {
                throw PatchError.outputVerificationFailed(
                    "二进制补丁结果哈希不匹配（\(binaryPath)：期望 \(expectedAfter.prefix(12))…，实际 \(actualAfter.prefix(12))…）"
                )
            }
        }

        return edited
    }

    public static func decodeHex(_ hex: String, binaryPath: String, offset: Int) throws -> Data {
        guard hex.count % 2 == 0 else {
            throw PatchError.preimageMismatch(binaryPath: binaryPath, offset: offset)
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                throw PatchError.preimageMismatch(binaryPath: binaryPath, offset: offset)
            }
            bytes.append(byte)
            index = nextIndex
        }
        return Data(bytes)
    }
}
