import Foundation
import IPAPatcherCore

enum CLICommand {
    static func run() -> Int32 {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let subcommand = args.first else {
            printUsage()
            return 2
        }

        do {
            switch subcommand {
            case "verify-kit":
                let engine = try IPAPatcherEngine.builtInDefault()
                let kits = try engine.verifyConfiguredKits()
                for kit in kits {
                    print("OK: \(kit.manifest.revision) | manifest=\(kit.manifestSHA256) | payload=\(kit.payloadZipSHA256) | entries=\(kit.payloadEntryCount)")
                }
                return 0

            case "inspect":
                guard args.count >= 2 else {
                    fputs("Usage: ipa-patcher-cli inspect <ipa-path>\n", stderr)
                    return 2
                }
                let url = URL(fileURLWithPath: args[1])
                let profile = try HostInspector().inspect(ipaURL: url, options: .default)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(profile)
                print(String(decoding: data, as: UTF8.self))
                return 0

            case "self-check":
                guard args.count >= 2 else {
                    fputs("Usage: ipa-patcher-cli self-check <ipa-path>\n", stderr)
                    return 2
                }
                let engine = try IPAPatcherEngine.builtInDefault()
                let url = URL(fileURLWithPath: args[1])
                let (host, report, comparisons) = try engine.selfCheckAutoResolver(ipaURL: url)
                let matched = comparisons.filter(\.isMatch).count
                let statusStr = report.isConfirmedCompatible ? "CONFIRMED" : "UNVERIFIED"
                print("SELF-CHECK [\(statusStr)]: \(host.version) (build \(host.build)) | IL2CPP v\(report.metadataVersion) | \(matched)/\(comparisons.count) matched (\(String(format: "%.2fs", report.durationSeconds)))")
                for reason in report.unverifiedReasons {
                    print("  [UNVERIFIED] \(reason)")
                }
                for c in comparisons {
                    let mark = c.isMatch ? "OK" : "DIFF"
                    print("  [\(mark)] \(c.key): resolved=\(IL2CPPOffsetSet.hexString(c.resolved)) expected=\(IL2CPPOffsetSet.hexString(c.expected))")
                }
                return (report.isConfirmedCompatible && matched == comparisons.count) ? 0 : 1

            case "match":
                guard args.count >= 2 else {
                    fputs("Usage: ipa-patcher-cli match <ipa-path> [--profile <path>] [--no-auto]\n", stderr)
                    return 2
                }
                let engine = try IPAPatcherEngine.builtInDefault()
                let url = URL(fileURLWithPath: args[1])
                let parsed = try parseFlags(Array(args.dropFirst(2)))
                let kits = try engine.verifyConfiguredKits()
                let session = try engine.openInputSession(at: url)
                let profile = try engine.inspectHost(session: session)
                let result = try engine.matchCompatibility(
                    for: profile,
                    verifiedKits: kits,
                    customProfiles: parsed.customProfiles,
                    options: parsed.options,
                    sourceIPAURL: url,
                    inputSession: session
                )
                switch result {
                case .matched(let config):
                    print("MATCHED [\(config.adaptationMode.rawValue)]: \(config.effectiveRevision) for \(profile.bundleID) \(profile.version) (build \(profile.build))")
                    return 0
                case .incompatible(let report):
                    fputs("INCOMPATIBLE: \(report.summaryText)\n", stderr)
                    for item in report.mismatches {
                        fputs("  - [\(item.fieldLabel)] expected=\(item.expected) actual=\(item.actual) (\(item.detail))\n", stderr)
                    }
                    return 1
                }

            case "patch":
                guard args.count >= 3 else {
                    fputs("Usage: ipa-patcher-cli patch <input-ipa> <output-dir> [--original-icon] [--profile <path>] [--no-auto] [--force]\n", stderr)
                    return 2
                }
                let engine = try IPAPatcherEngine.builtInDefault()
                let inputURL = URL(fileURLWithPath: args[1])
                let outputDir = URL(fileURLWithPath: args[2])
                let parsed = try parseFlags(Array(args.dropFirst(3)))
                let loadedKits = try engine.loadAndVerifyConfiguredKits()
                let kits = loadedKits.map(\.verifiedKit)
                let session = try engine.openInputSession(at: inputURL)
                let profile = try engine.inspectHost(session: session)
                let match = try engine.matchCompatibility(
                    for: profile,
                    verifiedKits: kits,
                    customProfiles: parsed.customProfiles,
                    options: parsed.options,
                    sourceIPAURL: inputURL,
                    inputSession: session
                )
                guard case .matched(let config) = match else {
                    if case .incompatible(let report) = match {
                        fputs("STOP: \(report.summaryText)\n", stderr)
                    }
                    return 1
                }
                let matchedPreloaded = loadedKits.first { $0.verifiedKit.profile == config.profile }
                let result = try engine.applyPatch(
                    configuration: config,
                    sourceIPAURL: inputURL,
                    workingDirectory: outputDir,
                    options: parsed.options,
                    inputSession: session,
                    preloadedKit: matchedPreloaded,
                    overwriteExistingOutput: parsed.overwriteExisting
                )
                print("SUCCESS [\(result.adaptationMode.rawValue) | icon=\(result.appliedCustomBiliIcons ? "bili" : "orig")]: \(result.outputURL.path)")
                print("Size: \(result.outputBytes) bytes")
                print("Preserved: \(result.preservedSourceFiles), Modified: \(result.modifiedEntries.count), Added: \(result.addedEntries.count), Removed: \(result.removedEntries.count)")
                return 0

            default:
                printUsage()
                return 2
            }
        } catch {
            fputs("ERROR: \(error.localizedDescription)\n", stderr)
            return 2
        }
    }

    private struct ParsedFlags {
        var customProfiles: [RuntimeOffsetProfile] = []
        var options = PatchOptions.default
        var overwriteExisting = false
    }

    private static func parseFlags(_ flags: [String]) throws -> ParsedFlags {
        var parsed = ParsedFlags()
        var idx = 0
        while idx < flags.count {
            let f = flags[idx]
            if f == "--original-icon" {
                parsed.options.applyCustomBiliIcons = false
            } else if f == "--no-auto" {
                parsed.options.enableAutoAdaptation = false
            } else if f == "--force" {
                parsed.overwriteExisting = true
            } else if f == "--profile" {
                guard idx + 1 < flags.count else {
                    throw PatchError.invalidCustomProfile("参数 --profile 缺少文件路径")
                }
                let data = try Data(contentsOf: URL(fileURLWithPath: flags[idx + 1]))
                parsed.customProfiles.append(try RuntimeOffsetProfile.decode(from: data))
                idx += 1
            } else {
                throw PatchError.invalidCustomProfile("未知命令行参数：\(f)")
            }
            idx += 1
        }
        return parsed
    }

    private static func printUsage() {
        fputs(
            """
            Usage:
              ipa-patcher-cli verify-kit
              ipa-patcher-cli inspect <ipa-path>
              ipa-patcher-cli self-check <ipa-path>
              ipa-patcher-cli match <ipa-path> [--profile <json/plist>] [--no-auto]
              ipa-patcher-cli patch <input-ipa> <output-dir> [--original-icon] [--profile <json/plist>] [--no-auto] [--force]
            """,
            stderr
        )
    }
}

exit(CLICommand.run())
