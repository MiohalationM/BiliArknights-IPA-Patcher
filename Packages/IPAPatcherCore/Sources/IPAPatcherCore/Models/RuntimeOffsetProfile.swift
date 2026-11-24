import Foundation

/// All 14 Unity IL2CPP runtime RVAs required by `ABRuntime.m` inside `ABLoginBridge.dylib`.
public struct IL2CPPOffsetSet: Sendable, Hashable, Codable {
    public let sdkInterfaceClassSlot: UInt64
    public let sdkExternalToolsClassSlot: UInt64
    public let sdkMetaClassSlot: UInt64
    public let networkerTypeSlot: UInt64
    public let networkerExpectedClass: UInt64
    public let gameFlowClassSlot: UInt64

    public let getNetworkConfigFn: UInt64
    public let overrideNetworkOptionsFn: UInt64
    public let createStringFn: UInt64
    public let internalSDKMetaFn: UInt64
    public let sdkMetaCtorFn: UInt64
    public let clearAuthStatusFn: UInt64
    public let clearLoginStatusFn: UInt64
    public let getCurrentSceneFn: UInt64

    /// Verified Arknights 2.7.91 / build 76 ground truth offsets.
    public static let builtIn2791 = IL2CPPOffsetSet(
        sdkInterfaceClassSlot: 0x0b9a_5e38,
        sdkExternalToolsClassSlot: 0x0b99_d618,
        sdkMetaClassSlot: 0x0b99_d6c0,
        networkerTypeSlot: 0x0ba1_cc48,
        networkerExpectedClass: 0x0604_9b80,
        gameFlowClassSlot: 0x0b98_f408,
        getNetworkConfigFn: 0x077a_d3ac,
        overrideNetworkOptionsFn: 0x077a_d968,
        createStringFn: 0x07dc_af48,
        internalSDKMetaFn: 0x06c5_aff4,
        sdkMetaCtorFn: 0x06c6_2a84,
        clearAuthStatusFn: 0x06c5_c478,
        clearLoginStatusFn: 0x06c5_c53c,
        getCurrentSceneFn: 0x0181_78d4
    )

    public init(
        sdkInterfaceClassSlot: UInt64,
        sdkExternalToolsClassSlot: UInt64,
        sdkMetaClassSlot: UInt64,
        networkerTypeSlot: UInt64,
        networkerExpectedClass: UInt64,
        gameFlowClassSlot: UInt64,
        getNetworkConfigFn: UInt64,
        overrideNetworkOptionsFn: UInt64,
        createStringFn: UInt64,
        internalSDKMetaFn: UInt64,
        sdkMetaCtorFn: UInt64,
        clearAuthStatusFn: UInt64,
        clearLoginStatusFn: UInt64,
        getCurrentSceneFn: UInt64
    ) {
        self.sdkInterfaceClassSlot = sdkInterfaceClassSlot
        self.sdkExternalToolsClassSlot = sdkExternalToolsClassSlot
        self.sdkMetaClassSlot = sdkMetaClassSlot
        self.networkerTypeSlot = networkerTypeSlot
        self.networkerExpectedClass = networkerExpectedClass
        self.gameFlowClassSlot = gameFlowClassSlot
        self.getNetworkConfigFn = getNetworkConfigFn
        self.overrideNetworkOptionsFn = overrideNetworkOptionsFn
        self.createStringFn = createStringFn
        self.internalSDKMetaFn = internalSDKMetaFn
        self.sdkMetaCtorFn = sdkMetaCtorFn
        self.clearAuthStatusFn = clearAuthStatusFn
        self.clearLoginStatusFn = clearLoginStatusFn
        self.getCurrentSceneFn = getCurrentSceneFn
    }

    enum CodingKeys: String, CodingKey {
        case sdkInterfaceClassSlot
        case sdkExternalToolsClassSlot
        case sdkMetaClassSlot
        case networkerTypeSlot
        case networkerExpectedClass
        case gameFlowClassSlot
        case getNetworkConfigFn
        case overrideNetworkOptionsFn
        case createStringFn
        case internalSDKMetaFn
        case sdkMetaCtorFn
        case clearAuthStatusFn
        case clearLoginStatusFn
        case getCurrentSceneFn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sdkInterfaceClassSlot = try Self.decodeFlexUInt64(c, key: .sdkInterfaceClassSlot)
        self.sdkExternalToolsClassSlot = try Self.decodeFlexUInt64(c, key: .sdkExternalToolsClassSlot)
        self.sdkMetaClassSlot = try Self.decodeFlexUInt64(c, key: .sdkMetaClassSlot)
        self.networkerTypeSlot = try Self.decodeFlexUInt64(c, key: .networkerTypeSlot)
        self.networkerExpectedClass = try Self.decodeFlexUInt64Optional(c, key: .networkerExpectedClass) ?? 0
        self.gameFlowClassSlot = try Self.decodeFlexUInt64(c, key: .gameFlowClassSlot)
        self.getNetworkConfigFn = try Self.decodeFlexUInt64(c, key: .getNetworkConfigFn)
        self.overrideNetworkOptionsFn = try Self.decodeFlexUInt64(c, key: .overrideNetworkOptionsFn)
        self.createStringFn = try Self.decodeFlexUInt64(c, key: .createStringFn)
        self.internalSDKMetaFn = try Self.decodeFlexUInt64(c, key: .internalSDKMetaFn)
        self.sdkMetaCtorFn = try Self.decodeFlexUInt64(c, key: .sdkMetaCtorFn)
        self.clearAuthStatusFn = try Self.decodeFlexUInt64(c, key: .clearAuthStatusFn)
        self.clearLoginStatusFn = try Self.decodeFlexUInt64(c, key: .clearLoginStatusFn)
        self.getCurrentSceneFn = try Self.decodeFlexUInt64(c, key: .getCurrentSceneFn)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.hexString(sdkInterfaceClassSlot), forKey: .sdkInterfaceClassSlot)
        try c.encode(Self.hexString(sdkExternalToolsClassSlot), forKey: .sdkExternalToolsClassSlot)
        try c.encode(Self.hexString(sdkMetaClassSlot), forKey: .sdkMetaClassSlot)
        try c.encode(Self.hexString(networkerTypeSlot), forKey: .networkerTypeSlot)
        try c.encode(Self.hexString(networkerExpectedClass), forKey: .networkerExpectedClass)
        try c.encode(Self.hexString(gameFlowClassSlot), forKey: .gameFlowClassSlot)
        try c.encode(Self.hexString(getNetworkConfigFn), forKey: .getNetworkConfigFn)
        try c.encode(Self.hexString(overrideNetworkOptionsFn), forKey: .overrideNetworkOptionsFn)
        try c.encode(Self.hexString(createStringFn), forKey: .createStringFn)
        try c.encode(Self.hexString(internalSDKMetaFn), forKey: .internalSDKMetaFn)
        try c.encode(Self.hexString(sdkMetaCtorFn), forKey: .sdkMetaCtorFn)
        try c.encode(Self.hexString(clearAuthStatusFn), forKey: .clearAuthStatusFn)
        try c.encode(Self.hexString(clearLoginStatusFn), forKey: .clearLoginStatusFn)
        try c.encode(Self.hexString(getCurrentSceneFn), forKey: .getCurrentSceneFn)
    }

    /// All 14 named offset entries for diagnostics and UI comparison.
    public var namedEntries: [(key: String, label: String, value: UInt64, optional: Bool)] {
        [
            ("sdkInterfaceClassSlot", "U8SDKInterface TypeInfo 槽位", sdkInterfaceClassSlot, false),
            ("sdkExternalToolsClassSlot", "SDKExternalTools TypeInfo 槽位", sdkExternalToolsClassSlot, false),
            ("sdkMetaClassSlot", "SDKMeta TypeInfo 槽位", sdkMetaClassSlot, false),
            ("networkerTypeSlot", "Networker 单例 MethodInfo 槽位", networkerTypeSlot, false),
            ("networkerExpectedClass", "Networker 单例方法指针校验", networkerExpectedClass, true),
            ("gameFlowClassSlot", "GameFlowController TypeInfo 槽位", gameFlowClassSlot, false),
            ("getNetworkConfigFn", "Networker.get_networkConfig", getNetworkConfigFn, false),
            ("overrideNetworkOptionsFn", "Networker.OverrideNetworkOptions", overrideNetworkOptionsFn, false),
            ("createStringFn", "String.CreateStringForSByteConstructor", createStringFn, false),
            ("internalSDKMetaFn", "U8SDKInterface._InternalSDKMeta", internalSDKMetaFn, false),
            ("sdkMetaCtorFn", "SDKMeta..ctor(string)", sdkMetaCtorFn, false),
            ("clearAuthStatusFn", "U8SDKInterface.ClearAuthStatus", clearAuthStatusFn, false),
            ("clearLoginStatusFn", "U8SDKInterface.ClearLoginStatus", clearLoginStatusFn, false),
            ("getCurrentSceneFn", "GameFlowController.get_currentScene", getCurrentSceneFn, false),
        ]
    }

    public func validateRequiredNonZero() throws {
        for entry in namedEntries where !entry.optional {
            if entry.value == 0 {
                throw PatchError.invalidCustomProfile("缺少必需的 IL2CPP 偏移字段或值为 0：\(entry.key)")
            }
        }
    }

    public func toPlistDictionary() -> [String: Any] {
        [
            "sdkInterfaceClassSlot": Self.hexString(sdkInterfaceClassSlot),
            "sdkExternalToolsClassSlot": Self.hexString(sdkExternalToolsClassSlot),
            "sdkMetaClassSlot": Self.hexString(sdkMetaClassSlot),
            "networkerTypeSlot": Self.hexString(networkerTypeSlot),
            "networkerExpectedClass": Self.hexString(networkerExpectedClass),
            "gameFlowClassSlot": Self.hexString(gameFlowClassSlot),
            "getNetworkConfigFn": Self.hexString(getNetworkConfigFn),
            "overrideNetworkOptionsFn": Self.hexString(overrideNetworkOptionsFn),
            "createStringFn": Self.hexString(createStringFn),
            "internalSDKMetaFn": Self.hexString(internalSDKMetaFn),
            "sdkMetaCtorFn": Self.hexString(sdkMetaCtorFn),
            "clearAuthStatusFn": Self.hexString(clearAuthStatusFn),
            "clearLoginStatusFn": Self.hexString(clearLoginStatusFn),
            "getCurrentSceneFn": Self.hexString(getCurrentSceneFn),
        ]
    }

    public static func hexString(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16)
    }

    public static func parseFlexibleUInt64(_ raw: Any?) -> UInt64? {
        if let n = raw as? NSNumber {
            return n.uint64Value
        }
        if let s = raw as? String {
            return parseHexOrDecimal(s)
        }
        return nil
    }

    public static func parseHexOrDecimal(_ raw: String) -> UInt64? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            return UInt64(trimmed.dropFirst(2), radix: 16)
        }
        return UInt64(trimmed, radix: 10)
    }

    private static func decodeFlexUInt64(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> UInt64 {
        if let intVal = try? container.decode(UInt64.self, forKey: key) {
            return intVal
        }
        if let strVal = try? container.decode(String.self, forKey: key),
           let parsed = parseHexOrDecimal(strVal) {
            return parsed
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "期望整数或 0x 十六进制偏移字符串"
        )
    }

    private static func decodeFlexUInt64Optional(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> UInt64? {
        guard container.contains(key) else { return nil }
        if (try? container.decodeNil(forKey: key)) == true { return nil }
        return try decodeFlexUInt64(container, key: key)
    }
}

/// A portable, version-specific IL2CPP runtime offset profile that can be either:
/// - manually imported by the user (`.json` or `.plist`) to adapt future game updates without rebuilding the App, or
/// - automatically synthesized on-device by `IL2CPPAutoResolver`.
public struct RuntimeOffsetProfile: Sendable, Hashable, Codable, Identifiable {
    public let schema: Int
    public let id: String
    public let name: String
    public let revision: String
    public let bundleID: String
    public let version: String
    public let build: String
    public let unityUUID: String
    public let unityTextSize: UInt64?
    public let unityTextSHA256: String?
    public let il2cppOffsets: IL2CPPOffsetSet
    public let notes: String?
    public let importedAt: Date?

    public init(
        schema: Int = 1,
        id: String? = nil,
        name: String,
        revision: String,
        bundleID: String = "com.hypergryph.arknights",
        version: String,
        build: String,
        unityUUID: String,
        unityTextSize: UInt64? = nil,
        unityTextSHA256: String? = nil,
        il2cppOffsets: IL2CPPOffsetSet,
        notes: String? = nil,
        importedAt: Date? = nil
    ) {
        let normalizedUUID = unityUUID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.schema = schema
        self.id = id ?? "\(bundleID)-\(version)-b\(build)-\(normalizedUUID.prefix(8))"
        self.name = name
        self.revision = revision
        self.bundleID = bundleID
        self.version = version
        self.build = build
        self.unityUUID = normalizedUUID
        self.unityTextSize = (unityTextSize ?? 0) > 0 ? unityTextSize : nil
        let cleanedSHA = unityTextSHA256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.unityTextSHA256 = (cleanedSHA?.isEmpty == false) ? cleanedSHA : nil
        self.il2cppOffsets = il2cppOffsets
        self.notes = notes
        self.importedAt = importedAt
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case id
        case name
        case revision
        case bundleID
        case version
        case build
        case unityUUID
        case unityTextSize
        case unityTextSHA256
        case il2cppOffsets
        case notes
        case importedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        let schemaVal: Int
        if c.contains(.schema), (try? c.decodeNil(forKey: .schema)) != true {
            schemaVal = try c.decode(Int.self, forKey: .schema)
        } else {
            schemaVal = 1
        }

        let bundleIDVal: String
        if c.contains(.bundleID), (try? c.decodeNil(forKey: .bundleID)) != true {
            bundleIDVal = try c.decode(String.self, forKey: .bundleID)
        } else {
            bundleIDVal = "com.hypergryph.arknights"
        }

        let versionVal = try c.decode(String.self, forKey: .version)
        let buildVal: String
        if let strBuild = try? c.decode(String.self, forKey: .build) {
            buildVal = strBuild
        } else if let intBuild = try? c.decode(Int.self, forKey: .build) {
            buildVal = String(intBuild)
        } else {
            throw DecodingError.keyNotFound(CodingKeys.build, .init(codingPath: c.codingPath, debugDescription: "缺少有效的 build 字段"))
        }
        let uuidVal = (try c.decode(String.self, forKey: .unityUUID))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let revVal: String
        if c.contains(.revision), (try? c.decodeNil(forKey: .revision)) != true {
            revVal = try c.decode(String.self, forKey: .revision)
        } else {
            revVal = "manual-\(versionVal)-b\(buildVal)"
        }

        let nameVal: String
        if c.contains(.name), (try? c.decodeNil(forKey: .name)) != true {
            nameVal = try c.decode(String.self, forKey: .name)
        } else {
            nameVal = "明日方舟 \(versionVal) (build \(buildVal))"
        }

        let idVal: String
        if c.contains(.id), (try? c.decodeNil(forKey: .id)) != true {
            idVal = try c.decode(String.self, forKey: .id)
        } else {
            idVal = "\(bundleIDVal)-\(versionVal)-b\(buildVal)-\(uuidVal.prefix(8))"
        }

        var textSizeVal: UInt64?
        if c.contains(.unityTextSize), (try? c.decodeNil(forKey: .unityTextSize)) != true {
            if let u = try? c.decode(UInt64.self, forKey: .unityTextSize) {
                textSizeVal = u
            } else if let s = try? c.decode(String.self, forKey: .unityTextSize) {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    textSizeVal = nil
                } else if let parsed = IL2CPPOffsetSet.parseHexOrDecimal(trimmed) {
                    textSizeVal = parsed
                } else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .unityTextSize,
                        in: c,
                        debugDescription: "unityTextSize 必须为整数或 0x 十六进制字符串"
                    )
                }
            } else {
                throw DecodingError.typeMismatch(
                    String.self,
                    .init(codingPath: c.codingPath + [CodingKeys.unityTextSize], debugDescription: "unityTextSize 类型无效")
                )
            }
        }

        let textSHAVal: String?
        if c.contains(.unityTextSHA256), (try? c.decodeNil(forKey: .unityTextSHA256)) != true {
            textSHAVal = try c.decode(String.self, forKey: .unityTextSHA256)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        } else {
            textSHAVal = nil
        }

        let offsetsVal = try c.decode(IL2CPPOffsetSet.self, forKey: .il2cppOffsets)
        let notesVal = try c.decodeIfPresent(String.self, forKey: .notes)
        let importedVal = try c.decodeIfPresent(Date.self, forKey: .importedAt)

        self.schema = schemaVal
        self.id = idVal
        self.name = nameVal
        self.revision = revVal
        self.bundleID = bundleIDVal
        self.version = versionVal
        self.build = buildVal
        self.unityUUID = uuidVal
        self.unityTextSize = (textSizeVal ?? 0) > 0 ? textSizeVal : nil
        self.unityTextSHA256 = (textSHAVal?.isEmpty == false) ? textSHAVal : nil
        self.il2cppOffsets = offsetsVal
        self.notes = notesVal
        self.importedAt = importedVal
    }

    /// Parses either a JSON profile or an XML/binary PropertyList (`ABRuntimeProfile.plist`) profile.
    public static func decode(from data: Data) throws -> RuntimeOffsetProfile {
        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601

        let jsonError: Error
        do {
            let parsed = try jsonDecoder.decode(RuntimeOffsetProfile.self, from: data)
            try parsed.validate()
            return parsed
        } catch let patchError as PatchError {
            throw patchError
        } catch {
            jsonError = error
        }

        // Try standard PropertyList (XML or binary `ABRuntimeProfile.plist`).
        if let plistObj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let dict = plistObj as? [String: Any] {
            let parsed = try decodeFromPlistDictionary(dict)
            try parsed.validate()
            return parsed
        }

        throw PatchError.invalidCustomProfile(formatDecodingError(jsonError))
    }

    private static func formatDecodingError(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return "配置文件既不是有效的 JSON 也不是有效的 Plist：\(error.localizedDescription)"
        }
        func pathString(_ path: [CodingKey]) -> String {
            path.map(\.stringValue).joined(separator: ".")
        }
        switch decodingError {
        case .keyNotFound(let key, let ctx):
            let full = pathString(ctx.codingPath + [key])
            return "JSON 缺少必需字段：\(full)"
        case .typeMismatch(_, let ctx):
            let full = pathString(ctx.codingPath)
            return full.isEmpty ? "JSON 顶层结构类型无效" : "JSON 字段「\(full)」类型不匹配：\(ctx.debugDescription)"
        case .valueNotFound(_, let ctx):
            let full = pathString(ctx.codingPath)
            return "JSON 字段「\(full)」不能为空"
        case .dataCorrupted(let ctx):
            let full = pathString(ctx.codingPath)
            return full.isEmpty
                ? "配置文件既不是有效的 JSON 也不是有效的 Plist（\(ctx.debugDescription)）"
                : "JSON 字段「\(full)」格式无效：\(ctx.debugDescription)"
        @unknown default:
            return "配置文件解析失败：\(decodingError.localizedDescription)"
        }
    }

    private static func decodeFromPlistDictionary(_ dict: [String: Any]) throws -> RuntimeOffsetProfile {
        guard let version = (dict["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else {
            throw PatchError.invalidCustomProfile("Plist 缺少 version 字段")
        }
        let build: String
        if let bStr = dict["build"] as? String, !bStr.isEmpty {
            build = bStr
        } else if let bNum = dict["build"] as? NSNumber {
            build = bNum.stringValue
        } else {
            throw PatchError.invalidCustomProfile("Plist 缺少 build 字段")
        }
        guard let unityUUID = (dict["unityUUID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !unityUUID.isEmpty else {
            throw PatchError.invalidCustomProfile("Plist 缺少 unityUUID 字段")
        }
        guard let offsetsDict = dict["il2cppOffsets"] as? [String: Any] else {
            throw PatchError.invalidCustomProfile("Plist 缺少 il2cppOffsets 字典")
        }

        func reqOffset(_ key: String) throws -> UInt64 {
            guard let v = IL2CPPOffsetSet.parseFlexibleUInt64(offsetsDict[key]) else {
                throw PatchError.invalidCustomProfile("il2cppOffsets 缺少有效偏移字段：\(key)")
            }
            return v
        }

        let offsets = IL2CPPOffsetSet(
            sdkInterfaceClassSlot: try reqOffset("sdkInterfaceClassSlot"),
            sdkExternalToolsClassSlot: try reqOffset("sdkExternalToolsClassSlot"),
            sdkMetaClassSlot: try reqOffset("sdkMetaClassSlot"),
            networkerTypeSlot: try reqOffset("networkerTypeSlot"),
            networkerExpectedClass: IL2CPPOffsetSet.parseFlexibleUInt64(offsetsDict["networkerExpectedClass"]) ?? 0,
            gameFlowClassSlot: try reqOffset("gameFlowClassSlot"),
            getNetworkConfigFn: try reqOffset("getNetworkConfigFn"),
            overrideNetworkOptionsFn: try reqOffset("overrideNetworkOptionsFn"),
            createStringFn: try reqOffset("createStringFn"),
            internalSDKMetaFn: try reqOffset("internalSDKMetaFn"),
            sdkMetaCtorFn: try reqOffset("sdkMetaCtorFn"),
            clearAuthStatusFn: try reqOffset("clearAuthStatusFn"),
            clearLoginStatusFn: try reqOffset("clearLoginStatusFn"),
            getCurrentSceneFn: try reqOffset("getCurrentSceneFn")
        )

        let schema = (dict["schema"] as? NSNumber)?.intValue ?? 1
        let bundleID = (dict["bundleID"] as? String) ?? "com.hypergryph.arknights"
        let revision = (dict["revision"] as? String) ?? "manual-\(version)-b\(build)"
        let name = (dict["name"] as? String) ?? "明日方舟 \(version) (build \(build))"
        let textSize = IL2CPPOffsetSet.parseFlexibleUInt64(dict["unityTextSize"])
        let textSHA = dict["unityTextSHA256"] as? String
        let notes = dict["notes"] as? String

        return RuntimeOffsetProfile(
            schema: schema,
            name: name,
            revision: revision,
            bundleID: bundleID,
            version: version,
            build: build,
            unityUUID: unityUUID,
            unityTextSize: textSize,
            unityTextSHA256: textSHA,
            il2cppOffsets: offsets,
            notes: notes,
            importedAt: Date()
        )
    }

    public func validate() throws {
        guard schema == 1 else {
            throw PatchError.invalidCustomProfile("不支持的配置版本 schema=\(schema)（仅支持 schema=1）")
        }
        guard !bundleID.isEmpty else {
            throw PatchError.invalidCustomProfile("配置缺少 bundleID")
        }
        guard !version.isEmpty, !build.isEmpty else {
            throw PatchError.invalidCustomProfile("配置缺少 version 或 build")
        }
        guard UUID(uuidString: unityUUID) != nil else {
            throw PatchError.invalidCustomProfile("unityUUID 格式无效：\(unityUUID)")
        }
        let hasTextSize = (unityTextSize ?? 0) > 0
        let hasTextSHA = !(unityTextSHA256?.isEmpty ?? true)
        if hasTextSize != hasTextSHA {
            throw PatchError.invalidCustomProfile(
                "unityTextSize 与 unityTextSHA256 必须同时提供，或同时省略/置空（仅校验 Unity UUID）"
            )
        }
        if let sha = unityTextSHA256, !sha.isEmpty {
            let validHex = sha.count == 64 && sha.allSatisfy { $0.isHexDigit }
            guard validHex else {
                throw PatchError.invalidCustomProfile("unityTextSHA256 必须为 64 位十六进制 SHA-256")
            }
        }
        try il2cppOffsets.validateRequiredNonZero()
    }

    /// Encodes a clean human-readable JSON file (with `0x` hex offsets) suitable for sharing and re-importing.
    public func encodeToPrettyJSONData() throws -> Data {
        var root: [String: Any] = [
            "schema": schema,
            "name": name,
            "revision": revision,
            "bundleID": bundleID,
            "version": version,
            "build": build,
            "unityUUID": unityUUID.lowercased(),
            "il2cppOffsets": il2cppOffsets.toPlistDictionary(),
        ]
        if let size = unityTextSize, let sha = unityTextSHA256, size > 0, !sha.isEmpty {
            root["unityTextSize"] = IL2CPPOffsetSet.hexString(size)
            root["unityTextSHA256"] = sha.lowercased()
        }
        if let notes, !notes.isEmpty {
            root["notes"] = notes
        }
        do {
            return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw PatchError.invalidPatchedMetadata("生成 JSON 适配配置失败：\(error.localizedDescription)")
        }
    }

    public func encodeToPrettyJSONString() throws -> String {
        let data = try encodeToPrettyJSONData()
        return String(decoding: data, as: UTF8.self)
    }

    /// Encodes the exact binary `ABRuntimeProfile.plist` format consumed by `ABRuntime.m` & `ABHooks.m`.
    /// Always explicitly writes `unityTextSize` (`0x0` when omitted) and `unityTextSHA256` (`""` when omitted)
    /// so the bridge never inherits built-in 2.7.91 defaults.
    public func encodeToRuntimeProfilePlistData() throws -> Data {
        let root: [String: Any] = [
            "schema": schema,
            "revision": revision,
            "version": version,
            "build": build,
            "unityUUID": unityUUID.lowercased(),
            "unityTextSize": IL2CPPOffsetSet.hexString(unityTextSize ?? 0),
            "unityTextSHA256": (unityTextSHA256 ?? "").lowercased(),
            "il2cppOffsets": il2cppOffsets.toPlistDictionary(),
        ]
        do {
            return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        } catch {
            throw PatchError.invalidPatchedMetadata("生成 ABRuntimeProfile.plist 失败：\(error.localizedDescription)")
        }
    }

    /// Returns whether this profile matches the inspected host IPA (`bundleID + version + build + UnityFramework UUID`).
    public func matches(host: HostIPAProfile) -> Bool {
        guard host.bundleID == bundleID,
              host.version == version,
              host.build == build else {
            return false
        }
        let unityPath = host.appRoot + "Frameworks/UnityFramework.framework/UnityFramework"
        guard let unityBinary = host.binary(at: unityPath),
              let actualUUID = unityBinary.primaryUUID else {
            return false
        }
        return actualUUID.lowercased() == unityUUID.lowercased()
    }

    public func withImportedTimestamp(_ date: Date) -> RuntimeOffsetProfile {
        RuntimeOffsetProfile(
            schema: schema,
            id: id,
            name: name,
            revision: revision,
            bundleID: bundleID,
            version: version,
            build: build,
            unityUUID: unityUUID,
            unityTextSize: unityTextSize,
            unityTextSHA256: unityTextSHA256,
            il2cppOffsets: il2cppOffsets,
            notes: notes,
            importedAt: date
        )
    }

    public static var sampleJSONTemplate: String {
        """
        {
          "schema": 1,
          "name": "明日方舟 2.7.91 (build 76) 基准示例",
          "revision": "7.5-2.7.91-manual-sample",
          "bundleID": "com.hypergryph.arknights",
          "version": "2.7.91",
          "build": "76",
          "unityUUID": "386e1e29-f538-38c5-84d3-40427d3e6eb1",
          "unityTextSize": "0x99f7a28",
          "unityTextSHA256": "ef43071f7010d6c429f34bd4b9dd3e347941db43dfd3b47913e146fe98f67443",
          "il2cppOffsets": {
            "sdkInterfaceClassSlot": "0xb9a5e38",
            "sdkExternalToolsClassSlot": "0xb99d618",
            "sdkMetaClassSlot": "0xb99d6c0",
            "networkerTypeSlot": "0xba1cc48",
            "networkerExpectedClass": "0x6049b80",
            "gameFlowClassSlot": "0xb98f408",
            "getNetworkConfigFn": "0x77ad3ac",
            "overrideNetworkOptionsFn": "0x77ad968",
            "createStringFn": "0x7dcaf48",
            "internalSDKMetaFn": "0x6c5aff4",
            "sdkMetaCtorFn": "0x6c62a84",
            "clearAuthStatusFn": "0x6c5c478",
            "clearLoginStatusFn": "0x6c5c53c",
            "getCurrentSceneFn": "0x18178d4"
          },
          "notes": "可替换为未来新版本的 Unity UUID 与 14 项 IL2CPP 偏移，无需更新 App。"
        }
        """
    }
}

/// How the patch engine resolved the runtime offsets for a given host IPA.
public enum AdaptationMode: String, Sendable, Hashable, Codable {
    case builtInVerified
    case manualCustomProfile
    case autoResolved

    public var badgeTitle: String {
        switch self {
        case .builtInVerified:
            return "内置适配"
        case .manualCustomProfile:
            return "导入配置"
        case .autoResolved:
            return "自动适配"
        }
    }

    public var detailTitle: String {
        switch self {
        case .builtInVerified:
            return "内置已验证版本 (2.7.91)"
        case .manualCustomProfile:
            return "手工导入配置文件"
        case .autoResolved:
            return "本机自动适配"
        }
    }
}

/// User-facing patch customization options.
public struct PatchOptions: Sendable, Hashable, Codable {
    /// When `true` (default), replaces App icon with B-server icon (`ABAppIcon*.png` + `CFBundleIcons`).
    /// When `false`, preserves the original host IPA's icon untouched.
    public var applyCustomBiliIcons: Bool

    /// When `true` (default), automatically runs on-device IL2CPP v29/v31 static resolution
    /// for future Arknights versions not covered by a manual profile or built-in baseline.
    public var enableAutoAdaptation: Bool

    public static let `default` = PatchOptions(
        applyCustomBiliIcons: true,
        enableAutoAdaptation: true
    )

    public init(
        applyCustomBiliIcons: Bool = true,
        enableAutoAdaptation: Bool = true
    ) {
        self.applyCustomBiliIcons = applyCustomBiliIcons
        self.enableAutoAdaptation = enableAutoAdaptation
    }
}
