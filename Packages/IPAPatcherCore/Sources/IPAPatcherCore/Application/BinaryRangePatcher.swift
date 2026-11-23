import Foundation

/// Applies verified byte-range patches to host Mach-O binaries, strictly validating every preimage byte first.
public enum BinaryRangePatcher {
    public static func apply(
        raw: Data,
        spec: PatchKitManifest.BinaryPatchSpec,
        binaryPath: String
    ) throws -> Data {
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
