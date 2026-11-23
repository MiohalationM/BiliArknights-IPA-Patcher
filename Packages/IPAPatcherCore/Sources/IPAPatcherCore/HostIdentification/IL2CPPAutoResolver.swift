import CryptoKit
import Foundation
import Zip64Kit

/// Resolution trace for a single IL2CPP runtime offset.
public struct IL2CPPResolvedItem: Sendable, Hashable, Codable, Identifiable {
    public var id: String { key }
    public let key: String
    public let label: String
    public let rva: UInt64
    public let strategy: String
    public let candidateCount: Int

    public init(
        key: String,
        label: String,
        rva: UInt64,
        strategy: String,
        candidateCount: Int = 1
    ) {
        self.key = key
        self.label = label
        self.rva = rva
        self.strategy = strategy
        self.candidateCount = candidateCount
    }
}

/// Comparison item used when self-checking `IL2CPPAutoResolver` against a verified baseline (e.g. 2.7.91/76).
public struct IL2CPPOffsetComparison: Sendable, Hashable, Identifiable {
    public var id: String { key }
    public let key: String
    public let label: String
    public let expected: UInt64
    public let resolved: UInt64
    public let optional: Bool

    public var isMatch: Bool {
        if optional && expected == 0 { return true }
        return expected == resolved
    }

    public init(key: String, label: String, expected: UInt64, resolved: UInt64, optional: Bool) {
        self.key = key
        self.label = label
        self.expected = expected
        self.resolved = resolved
        self.optional = optional
    }
}

/// Two-state verification outcome separating "candidate offsets located" from "confirmed ABI-compatible for export".
public enum IL2CPPResolutionStatus: Sendable, Hashable {
    case confirmedCompatible
    case candidatesUnverified(reasons: [String])
}

/// Complete output from `IL2CPPAutoResolver`.
public struct IL2CPPAutoResolutionReport: Sendable, Hashable {
    public let status: IL2CPPResolutionStatus
    public let profile: RuntimeOffsetProfile?
    public let metadataVersion: Int
    public let imageCount: Int
    public let typeDefinitionCount: Int
    public let sdkMetaFieldsVerified: [String]
    public let networkConfigStringFieldCount: Int
    public let abiChecksSummary: String
    public let items: [IL2CPPResolvedItem]
    public let durationSeconds: TimeInterval

    public var isConfirmedCompatible: Bool {
        if case .confirmedCompatible = status, profile != nil {
            return true
        }
        return false
    }

    public var unverifiedReasons: [String] {
        switch status {
        case .confirmedCompatible:
            return []
        case .candidatesUnverified(let reasons):
            return reasons
        }
    }

    public var summaryText: String {
        switch status {
        case .confirmedCompatible:
            return "IL2CPP v\(metadataVersion) · \(imageCount) 模块 · \(typeDefinitionCount) 类型 · 已确认兼容（\(abiChecksSummary)）"
        case .candidatesUnverified(let reasons):
            return "IL2CPP v\(metadataVersion) · 已找到部分候选，但缺少足够兼容性证据（\(reasons.count) 项未确认）"
        }
    }
}

/// Pure-Swift, single-IPA on-device Unity IL2CPP v27/v29/v31 static resolver.
/// Parses `global-metadata.dat` and `UnityFramework` directly from a decrypted host IPA
/// to resolve all 14 `ABRuntimeProfile.plist` offsets, verify unique method overload signatures,
/// and prove exact byte-level struct ABI invariants (`fieldOffsets` + `typeDefinitionsSizes`).
public struct IL2CPPAutoResolver: Sendable {
    public init() {}

    public func resolve(
        sourceIPAURL: URL,
        hostProfile: HostIPAProfile,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) throws -> IL2CPPAutoResolutionReport {
        let session = try PatchInputSession(ipaURL: sourceIPAURL)
        return try resolve(session: session, hostProfile: hostProfile, onProgress: onProgress)
    }

    public func resolve(
        session: PatchInputSession,
        hostProfile: HostIPAProfile,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) throws -> IL2CPPAutoResolutionReport {
        let unityPath = hostProfile.appRoot + "Frameworks/UnityFramework.framework/UnityFramework"
        let cachedUnity = session.cachedUnityFrameworkData(at: unityPath)
        return try resolve(
            reader: session.reader,
            hostProfile: hostProfile,
            unityFrameworkData: cachedUnity,
            cacheUnityData: { data in
                session.storeUnityFrameworkData(data, at: unityPath)
            },
            onProgress: onProgress
        )
    }

    public func resolve(
        reader: Zip64Reader,
        hostProfile: HostIPAProfile,
        unityFrameworkData: Data? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) throws -> IL2CPPAutoResolutionReport {
        try resolve(
            reader: reader,
            hostProfile: hostProfile,
            unityFrameworkData: unityFrameworkData,
            cacheUnityData: nil,
            onProgress: onProgress
        )
    }

    private func resolve(
        reader: Zip64Reader,
        hostProfile: HostIPAProfile,
        unityFrameworkData: Data?,
        cacheUnityData: ((Data) -> Void)?,
        onProgress: (@Sendable (String) -> Void)?
    ) throws -> IL2CPPAutoResolutionReport {
        try Task.checkCancellation()
        let metadataPath = hostProfile.appRoot + "Data/Managed/Metadata/global-metadata.dat"
        let unityPath = hostProfile.appRoot + "Frameworks/UnityFramework.framework/UnityFramework"

        onProgress?("正在读取 global-metadata.dat 元数据…")
        let metadataData: Data
        do {
            metadataData = try reader.readData(named: metadataPath)
        } catch is CancellationError {
            throw CancellationError()
        } catch let zipErr as ZipError {
            throw PatchError.zipFailure(zipErr)
        } catch {
            throw PatchError.autoResolutionFailed("未能在 IPA 中读取 \(metadataPath)：\(error.localizedDescription)")
        }

        let unityData: Data
        if let provided = unityFrameworkData {
            unityData = provided
        } else {
            onProgress?("正在读取 UnityFramework 主二进制…")
            do {
                unityData = try reader.readData(named: unityPath)
                cacheUnityData?(unityData)
            } catch is CancellationError {
                throw CancellationError()
            } catch let zipErr as ZipError {
                throw PatchError.zipFailure(zipErr)
            } catch {
                throw PatchError.autoResolutionFailed("未能在 IPA 中读取 \(unityPath)：\(error.localizedDescription)")
            }
        }

        return try resolve(
            globalMetadataData: metadataData,
            unityFrameworkData: unityData,
            hostProfile: hostProfile,
            onProgress: onProgress
        )
    }

    public func resolve(
        globalMetadataData: Data,
        unityFrameworkData: Data,
        hostProfile: HostIPAProfile,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) throws -> IL2CPPAutoResolutionReport {
        let startTime = Date()
        try Task.checkCancellation()

        // 1. Parse `global-metadata.dat` (v27 / v29 / v31).
        onProgress?("正在解析 global-metadata.dat 类型、方法与参数表…")
        let metadata = try GlobalMetadataParser(data: globalMetadataData)

        // 2. Parse `UnityFramework` Mach-O 64-bit sections & `LC_DYLD_CHAINED_FIXUPS`.
        onProgress?("正在解析 UnityFramework Mach-O 段表与指针格式…")
        let macho = try MachOImageReader(data: unityFrameworkData)

        guard let unityUUID = macho.uuid else {
            throw PatchError.autoResolutionFailed("UnityFramework 缺少 LC_UUID，无法生成运行时配置文件")
        }

        // 3. Locate `Il2CppCodeGenModule` array and `Il2CppCodeRegistration` via `"mscorlib.dll\0"`.
        try Task.checkCancellation()
        onProgress?("正在定位 Il2CppCodeGenModule 方法指针表…")
        let codeGenLookup = try locateCodeGenModules(macho: macho, metadata: metadata)

        // 4. Locate `Il2CppMetadataRegistration` via `typeDefinitionsCount` pair.
        try Task.checkCancellation()
        onProgress?("正在定位 Il2CppMetadataRegistration 泛型、字段偏移与类型尺寸表…")
        let metaReg = try locateMetadataRegistration(macho: macho, typeDefCount: metadata.typeDefinitions.count)

        // 5. Look up required C# TypeDefinitions (require exact uniqueness).
        onProgress?("正在匹配目标 C# 类、方法签名与精确字节偏移布局…")
        let networkerType = try requireUniqueType(metadata, namespace: "Torappu.Network", name: "Networker")
        let systemStringType = try requireUniqueType(metadata, namespace: "System", name: "String")
        let sdkInterfaceType = try requireUniqueType(metadata, namespace: "U8.SDK", name: "U8SDKInterface")
        let sdkExternalToolsType = try requireUniqueType(metadata, namespace: "U8.SDK", name: "SDKExternalTools")
        let sdkMetaType = try requireUniqueType(metadata, namespace: "U8.SDK", name: "SDKMeta")
        let gameFlowType = try requireUniqueType(metadata, namespace: "Torappu", name: "GameFlowController")

        // 6. Match all 8 target methods uniquely by name + parameter count + parameter/return types!
        let getNetworkConfigMethod = try requireUniqueMethod(
            metadata: metadata,
            type: networkerType,
            name: "get_networkConfig",
            paramCount: 0,
            metaReg: metaReg,
            macho: macho
        ) { retType, _ in
            retType.typeEnum == 0x11 // IL2CPP_TYPE_VALUETYPE (NetworkConfig)
        }

        // Verify exact `NetworkConfig` byte-level struct layout (104 bytes, 12 strings @ 0..88, bool dev @ 96).
        let networkConfigInfo = try verifyNetworkConfigLayout(
            metadata: metadata,
            returnTypeIndex: getNetworkConfigMethod.def.returnType,
            metaReg: metaReg,
            macho: macho
        )

        var abiVerificationIssues: [String] = []

        // Match `OverrideNetworkOptions` uniquely (2 params: NetworkOverride / Nullable<NetworkConfig>, int32/enum).
        let overrideNetworkMethod = try requireUniqueMethod(
            metadata: metadata,
            type: networkerType,
            name: "OverrideNetworkOptions",
            paramCount: 2,
            metaReg: metaReg,
            macho: macho
        ) { retType, paramTypes in
            guard retType.typeEnum == 0x01, paramTypes.count == 2 else { return false }
            let p0 = paramTypes[0].typeEnum
            let p1 = paramTypes[1].typeEnum
            let p0Ok = (p0 == 0x11 || p0 == 0x15) // ValueType struct or GenericInst Nullable<NetworkConfig>
            let p1Ok = (p1 == 0x08 || p1 == 0x09 || p1 == 0x11) // int32 / uint32 / enum
            return p0Ok && p1Ok
        }

        let overrideABIResult = verifyNetworkOverrideParamLayout(
            metadata: metadata,
            method: overrideNetworkMethod.def,
            expectedNetworkConfigTypeDefIndex: networkConfigInfo.typeDefIndex,
            metaReg: metaReg,
            macho: macho
        )
        switch overrideABIResult {
        case .success:
            break
        case .failure(let issue):
            abiVerificationIssues.append(issue.message)
        }

        let createStringMethod = try requireUniqueMethod(
            metadata: metadata,
            type: systemStringType,
            name: "CreateStringForSByteConstructor",
            paramCount: 2,
            metaReg: metaReg,
            macho: macho
        ) { retType, paramTypes in
            guard retType.typeEnum == 0x0e, paramTypes.count == 2 else { return false }
            let p0 = paramTypes[0].typeEnum
            let p1 = paramTypes[1].typeEnum
            let p0IsPtr = (p0 == 0x0f || p0 == 0x18 || p0 == 0x19) // byte*/sbyte* or IntPtr/UIntPtr
            let p1IsLen = (p1 == 0x08 || p1 == 0x09 || p1 == 0x18 || p1 == 0x19) // int32/uint32/nint/nuint
            return p0IsPtr && p1IsLen
        }

        let internalSDKMetaMethod = try requireUniqueMethod(
            metadata: metadata,
            type: sdkInterfaceType,
            name: "_InternalSDKMeta",
            paramCount: 0,
            metaReg: metaReg,
            macho: macho
        ) { retType, _ in
            retType.typeEnum == 0x12 && safeInt(retType.dataRaw, max: metadata.typeDefinitions.count - 1) == sdkMetaType.index
        }

        let sdkMetaCtorMethod = try requireUniqueMethod(
            metadata: metadata,
            type: sdkMetaType,
            name: ".ctor",
            paramCount: 1,
            metaReg: metaReg,
            macho: macho
        ) { _, paramTypes in
            paramTypes.count == 1 && paramTypes[0].typeEnum == 0x0e // IL2CPP_TYPE_STRING
        }

        let clearAuthMethod = try requireUniqueMethod(
            metadata: metadata,
            type: sdkInterfaceType,
            name: "ClearAuthStatus",
            paramCount: 0,
            metaReg: metaReg,
            macho: macho
        ) { retType, _ in
            retType.typeEnum == 0x01 // VOID
        }

        let clearLoginMethod = try requireUniqueMethod(
            metadata: metadata,
            type: sdkInterfaceType,
            name: "ClearLoginStatus",
            paramCount: 0,
            metaReg: metaReg,
            macho: macho
        ) { retType, _ in
            retType.typeEnum == 0x01 // VOID
        }

        let getCurrentSceneMethod = try requireUniqueMethod(
            metadata: metadata,
            type: gameFlowType,
            name: "get_currentScene",
            paramCount: 0,
            metaReg: metaReg,
            macho: macho
        ) { retType, _ in
            retType.typeEnum == 0x0e // STRING
        }

        // Helper methods for ARM64 `ADRP + LDR` slot cross-verification (must also be unique if present).
        let sdkInterfaceGetInstanceMethod = findUniqueOptionalMethod(metadata, in: sdkInterfaceType.index, names: ["get_Instance", "get_instance"], paramCount: 0)
        let sdkExternalToolsGetInstanceMethod = findUniqueOptionalMethod(metadata, in: sdkExternalToolsType.index, names: ["GetInstance", "get_Instance"], paramCount: 0)

        let getNetworkConfigRVA = try resolveMethodRVA(method: getNetworkConfigMethod.def, imageName: networkerType.imageName, codeGen: codeGenLookup, macho: macho)
        let overrideNetworkRVA = try resolveMethodRVA(method: overrideNetworkMethod.def, imageName: networkerType.imageName, codeGen: codeGenLookup, macho: macho)
        let createStringRVA = try resolveMethodRVA(method: createStringMethod.def, imageName: systemStringType.imageName, codeGen: codeGenLookup, macho: macho)
        let internalSDKMetaRVA = try resolveMethodRVA(method: internalSDKMetaMethod.def, imageName: sdkInterfaceType.imageName, codeGen: codeGenLookup, macho: macho)
        let sdkMetaCtorRVA = try resolveMethodRVA(method: sdkMetaCtorMethod.def, imageName: sdkMetaType.imageName, codeGen: codeGenLookup, macho: macho)
        let clearAuthRVA = try resolveMethodRVA(method: clearAuthMethod.def, imageName: sdkInterfaceType.imageName, codeGen: codeGenLookup, macho: macho)
        let clearLoginRVA = try resolveMethodRVA(method: clearLoginMethod.def, imageName: sdkInterfaceType.imageName, codeGen: codeGenLookup, macho: macho)
        let getCurrentSceneRVA = try resolveMethodRVA(method: getCurrentSceneMethod.def, imageName: gameFlowType.imageName, codeGen: codeGenLookup, macho: macho)

        let sdkInterfaceGetInstanceRVA = sdkInterfaceGetInstanceMethod.flatMap {
            try? resolveMethodRVA(method: $0.def, imageName: sdkInterfaceType.imageName, codeGen: codeGenLookup, macho: macho)
        }
        let sdkExternalToolsGetInstanceRVA = sdkExternalToolsGetInstanceMethod.flatMap {
            try? resolveMethodRVA(method: $0.def, imageName: sdkExternalToolsType.imageName, codeGen: codeGenLookup, macho: macho)
        }

        // 7. Verify `U8.SDK.SDKMeta` exact field names, types, AND compiled byte offsets (0x10..0x38).
        let verifiedSDKMetaFields = try verifySDKMetaLayout(
            metadata: metadata,
            sdkMetaType: sdkMetaType,
            metaReg: metaReg,
            macho: macho
        )
        if !networkConfigInfo.exactByteOffsetsVerified {
            abiVerificationIssues.append(networkConfigInfo.diagnosticNote)
        }
        if !verifiedSDKMetaFields.exactByteOffsetsVerified {
            abiVerificationIssues.append(verifiedSDKMetaFields.diagnosticNote)
        }

        // 8. Resolve `Singleton<Torappu.Network.Networker>.get_instance` MethodSpec & generic method pointer.
        try Task.checkCancellation()
        onProgress?("正在解析泛型单例与全局 TypeInfo 槽位…")
        let networkerSpec = try resolveNetworkerSingletonSpec(
            metadata: metadata,
            networkerType: networkerType,
            metaReg: metaReg,
            codeReg: codeGenLookup.codeRegistration,
            macho: macho
        )

        // 9. Single-pass scan over data sections for v27/v29 encoded MetadataUsage slots.
        guard sdkInterfaceType.def.byvalTypeIndex >= 0,
              sdkExternalToolsType.def.byvalTypeIndex >= 0,
              sdkMetaType.def.byvalTypeIndex >= 0,
              gameFlowType.def.byvalTypeIndex >= 0 else {
            throw PatchError.autoResolutionFailed("目标类型缺少有效的 byvalTypeIndex")
        }
        let tokSDKInterface = Self.encodeMetadataUsage(usage: 1, index: UInt32(sdkInterfaceType.def.byvalTypeIndex))
        let tokSDKExternalTools = Self.encodeMetadataUsage(usage: 1, index: UInt32(sdkExternalToolsType.def.byvalTypeIndex))
        let tokSDKMeta = Self.encodeMetadataUsage(usage: 1, index: UInt32(sdkMetaType.def.byvalTypeIndex))
        let tokGameFlow = Self.encodeMetadataUsage(usage: 1, index: UInt32(gameFlowType.def.byvalTypeIndex))
        let tokNetworkerMethodRef = Self.encodeMetadataUsage(usage: 6, index: UInt32(networkerSpec.methodSpecIndex))

        let targetTokens: Set<UInt64> = [
            tokSDKInterface,
            tokSDKExternalTools,
            tokSDKMeta,
            tokGameFlow,
            tokNetworkerMethodRef,
        ]
        let slotHitsByToken = macho.scanDataSectionsForRawUInt64s(targets: targetTokens)

        // 10. Resolve each global slot with strict uniqueness (never pick arbitrarily among multiple candidates).
        let sdkInterfaceSlotRes = resolveGlobalSlotStrict(
            label: "sdkInterfaceClassSlot",
            targetTypeIndex: sdkInterfaceType.index,
            expectedToken: tokSDKInterface,
            tokenHits: slotHitsByToken[tokSDKInterface] ?? [],
            helperMethodRVA: sdkInterfaceGetInstanceRVA,
            expectedUsage: 1,
            metadata: metadata,
            metaReg: metaReg,
            macho: macho
        )
        let sdkExternalToolsSlotRes = resolveGlobalSlotStrict(
            label: "sdkExternalToolsClassSlot",
            targetTypeIndex: sdkExternalToolsType.index,
            expectedToken: tokSDKExternalTools,
            tokenHits: slotHitsByToken[tokSDKExternalTools] ?? [],
            helperMethodRVA: sdkExternalToolsGetInstanceRVA,
            expectedUsage: 1,
            metadata: metadata,
            metaReg: metaReg,
            macho: macho
        )
        let sdkMetaSlotRes = resolveGlobalSlotStrict(
            label: "sdkMetaClassSlot",
            targetTypeIndex: sdkMetaType.index,
            expectedToken: tokSDKMeta,
            tokenHits: slotHitsByToken[tokSDKMeta] ?? [],
            helperMethodRVA: internalSDKMetaRVA,
            expectedUsage: 1,
            metadata: metadata,
            metaReg: metaReg,
            macho: macho
        )
        let gameFlowSlotRes = resolveGlobalSlotStrict(
            label: "gameFlowClassSlot",
            targetTypeIndex: gameFlowType.index,
            expectedToken: tokGameFlow,
            tokenHits: slotHitsByToken[tokGameFlow] ?? [],
            helperMethodRVA: getCurrentSceneRVA,
            expectedUsage: 1,
            metadata: metadata,
            metaReg: metaReg,
            macho: macho
        )
        let networkerSlotRes = resolveGlobalSlotStrict(
            label: "networkerTypeSlot",
            targetTypeIndex: nil,
            expectedToken: tokNetworkerMethodRef,
            tokenHits: slotHitsByToken[tokNetworkerMethodRef] ?? [],
            helperMethodRVA: nil,
            expectedUsage: 6,
            metadata: metadata,
            metaReg: metaReg,
            macho: macho
        )

        for slotRes in [sdkInterfaceSlotRes, sdkExternalToolsSlotRes, sdkMetaSlotRes, gameFlowSlotRes, networkerSlotRes] {
            if let issue = slotRes.issue {
                abiVerificationIssues.append(issue)
            }
        }

        let items: [IL2CPPResolvedItem] = [
            .init(key: "sdkInterfaceClassSlot", label: "U8SDKInterface TypeInfo", rva: sdkInterfaceSlotRes.rva, strategy: sdkInterfaceSlotRes.strategy, candidateCount: sdkInterfaceSlotRes.candidateCount),
            .init(key: "sdkExternalToolsClassSlot", label: "SDKExternalTools TypeInfo", rva: sdkExternalToolsSlotRes.rva, strategy: sdkExternalToolsSlotRes.strategy, candidateCount: sdkExternalToolsSlotRes.candidateCount),
            .init(key: "sdkMetaClassSlot", label: "SDKMeta TypeInfo", rva: sdkMetaSlotRes.rva, strategy: sdkMetaSlotRes.strategy, candidateCount: sdkMetaSlotRes.candidateCount),
            .init(key: "networkerTypeSlot", label: "Singleton<Networker> MethodInfo", rva: networkerSlotRes.rva, strategy: networkerSlotRes.strategy, candidateCount: networkerSlotRes.candidateCount),
            .init(key: "networkerExpectedClass", label: "Singleton<Networker>.get_instance 指针", rva: networkerSpec.methodPointerRVA, strategy: networkerSpec.pointerStrategy, candidateCount: networkerSpec.methodPointerRVA > 0 ? 1 : 0),
            .init(key: "gameFlowClassSlot", label: "GameFlowController TypeInfo", rva: gameFlowSlotRes.rva, strategy: gameFlowSlotRes.strategy, candidateCount: gameFlowSlotRes.candidateCount),
            .init(key: "getNetworkConfigFn", label: "Networker.get_networkConfig", rva: getNetworkConfigRVA, strategy: "CodeGenModule + 唯一签名匹配"),
            .init(key: "overrideNetworkOptionsFn", label: "Networker.OverrideNetworkOptions", rva: overrideNetworkRVA, strategy: "CodeGenModule + 唯一签名匹配"),
            .init(key: "createStringFn", label: "String.CreateStringForSByteConstructor", rva: createStringRVA, strategy: "CodeGenModule + 唯一签名匹配"),
            .init(key: "internalSDKMetaFn", label: "U8SDKInterface._InternalSDKMeta", rva: internalSDKMetaRVA, strategy: "CodeGenModule + 唯一签名匹配"),
            .init(key: "sdkMetaCtorFn", label: "SDKMeta..ctor(string)", rva: sdkMetaCtorRVA, strategy: "CodeGenModule + 唯一签名匹配"),
            .init(key: "clearAuthStatusFn", label: "U8SDKInterface.ClearAuthStatus", rva: clearAuthRVA, strategy: "CodeGenModule + 唯一签名匹配"),
            .init(key: "clearLoginStatusFn", label: "U8SDKInterface.ClearLoginStatus", rva: clearLoginRVA, strategy: "CodeGenModule + 唯一签名匹配"),
            .init(key: "getCurrentSceneFn", label: "GameFlowController.get_currentScene", rva: getCurrentSceneRVA, strategy: "CodeGenModule + 唯一签名匹配"),
        ]

        let abiSummary = "SDKMeta[0x10..0x38], NetworkConfig[104B, dev@96], Override[112B, cfg@8]"

        // If any slot was ambiguous/missing or any byte-level ABI invariant lacked full proof,
        // return `.candidatesUnverified` instead of authorizing an export!
        if !abiVerificationIssues.isEmpty {
            return IL2CPPAutoResolutionReport(
                status: .candidatesUnverified(reasons: abiVerificationIssues),
                profile: nil,
                metadataVersion: metadata.version,
                imageCount: metadata.images.count,
                typeDefinitionCount: metadata.typeDefinitions.count,
                sdkMetaFieldsVerified: verifiedSDKMetaFields.fieldNames,
                networkConfigStringFieldCount: networkConfigInfo.stringFieldCount,
                abiChecksSummary: abiSummary,
                items: items,
                durationSeconds: Date().timeIntervalSince(startTime)
            )
        }

        // 11. Compute `__TEXT.__text` hash so `ABHooks.m` can verify the exact UnityFramework image at runtime.
        onProgress?("正在计算 UnityFramework __text 代码段指纹…")
        let (textSize, textSHA256) = macho.computeTextSectionDigest()

        let offsets = IL2CPPOffsetSet(
            sdkInterfaceClassSlot: sdkInterfaceSlotRes.rva,
            sdkExternalToolsClassSlot: sdkExternalToolsSlotRes.rva,
            sdkMetaClassSlot: sdkMetaSlotRes.rva,
            networkerTypeSlot: networkerSlotRes.rva,
            networkerExpectedClass: networkerSpec.methodPointerRVA,
            gameFlowClassSlot: gameFlowSlotRes.rva,
            getNetworkConfigFn: getNetworkConfigRVA,
            overrideNetworkOptionsFn: overrideNetworkRVA,
            createStringFn: createStringRVA,
            internalSDKMetaFn: internalSDKMetaRVA,
            sdkMetaCtorFn: sdkMetaCtorRVA,
            clearAuthStatusFn: clearAuthRVA,
            clearLoginStatusFn: clearLoginRVA,
            getCurrentSceneFn: getCurrentSceneRVA
        )
        try offsets.validateRequiredNonZero()

        let profile = RuntimeOffsetProfile(
            schema: 1,
            name: "自动定位 · \(hostProfile.version) (build \(hostProfile.build))",
            revision: "7.5-\(hostProfile.version)-auto-il2cpp",
            bundleID: hostProfile.bundleID,
            version: hostProfile.version,
            build: hostProfile.build,
            unityUUID: unityUUID,
            unityTextSize: textSize,
            unityTextSHA256: textSHA256,
            il2cppOffsets: offsets,
            notes: "由本机单 IPA IL2CPP v\(metadata.version) 解析器生成并通过字节级结构体 ABI 与唯一性校验"
        )
        try profile.validate()

        return IL2CPPAutoResolutionReport(
            status: .confirmedCompatible,
            profile: profile,
            metadataVersion: metadata.version,
            imageCount: metadata.images.count,
            typeDefinitionCount: metadata.typeDefinitions.count,
            sdkMetaFieldsVerified: verifiedSDKMetaFields.fieldNames,
            networkConfigStringFieldCount: networkConfigInfo.stringFieldCount,
            abiChecksSummary: abiSummary,
            items: items,
            durationSeconds: Date().timeIntervalSince(startTime)
        )
    }

    public static func compare(
        resolved: IL2CPPOffsetSet,
        against expected: IL2CPPOffsetSet
    ) -> [IL2CPPOffsetComparison] {
        let expEntries = expected.namedEntries
        let resMap = Dictionary(uniqueKeysWithValues: resolved.namedEntries.map { ($0.key, $0.value) })
        return expEntries.map { entry in
            IL2CPPOffsetComparison(
                key: entry.key,
                label: entry.label,
                expected: entry.value,
                resolved: resMap[entry.key] ?? 0,
                optional: entry.optional
            )
        }
    }

    /// Encodes a Unity IL2CPP v27/v29/v31 `MetadataUsage` token as stored in uninitialized `__DATA` slots.
    public static func encodeMetadataUsage(usage: UInt32, index: UInt32) -> UInt64 {
        UInt64(((usage & 0x7) << 29) | ((index & 0x0FFF_FFFF) << 1) | 1)
    }

    // MARK: - Safe Arithmetic Helpers (Zero Trap Guarantees on Corrupted Input)

    @inline(__always)
    private func safeInt(_ raw: UInt64, max: Int) -> Int? {
        guard raw <= UInt64(max), let v = Int(exactly: raw) else { return nil }
        return v
    }

    @inline(__always)
    private func checkedTableRange(offset: Int, count: Int, stride: Int, limit: Int) -> Bool {
        guard offset >= 0, count >= 0, stride > 0, offset <= limit else { return false }
        let (byteLen, overflow) = count.multipliedReportingOverflow(by: stride)
        guard !overflow, byteLen >= 0 else { return false }
        return byteLen <= limit - offset
    }

    // MARK: - CodeGenModules & CodeRegistration Discovery

    private struct CodeGenModuleEntry {
        let moduleName: String
        let methodPointerCount: Int
        let methodPointersFileOffset: Int
    }

    private struct CodeRegistrationInfo {
        let genericMethodPointersCount: Int
        let genericMethodPointersFileOffset: Int
    }

    private struct CodeGenLookup {
        let modulesByName: [String: CodeGenModuleEntry]
        let codeRegistration: CodeRegistrationInfo?
    }

    private func locateCodeGenModules(
        macho: MachOImageReader,
        metadata: GlobalMetadataParser
    ) throws -> CodeGenLookup {
        let imageCount = metadata.images.count
        guard imageCount > 0 else {
            throw PatchError.autoResolutionFailed("global-metadata.dat 中未发现任何模块定义")
        }
        let expectedImageNames = Set(metadata.images.map(\.name))

        let mscorlibNeedle = Data("mscorlib.dll\0".utf8)
        let stringVAs = macho.findAllBytesInReadableSections(mscorlibNeedle)
        guard !stringVAs.isEmpty else {
            throw PatchError.autoResolutionFailed("在 UnityFramework 中未找到 \"mscorlib.dll\" 模块名锚点")
        }

        let stringVASet = Set(stringVAs)
        let moduleStructVAs = macho.findAllDataPointersTargeting(stringVASet).filter { candidateVA in
            guard let off = macho.vaToFileOffset(candidateVA),
                  checkedTableRange(offset: off, count: 3, stride: 8, limit: macho.data.count) else {
                return false
            }
            guard let methodCount = safeInt(macho.readUInt64LE(atFileOffset: off + 8), max: 2_000_000),
                  methodCount >= 1 else {
                return false
            }
            guard let ptrsVA = macho.readDecodedPointerVA(atFileOffset: off + 16),
                  let ptrsOff = macho.vaToFileOffset(ptrsVA),
                  checkedTableRange(offset: ptrsOff, count: methodCount, stride: 8, limit: macho.data.count) else {
                return false
            }
            return true
        }

        guard !moduleStructVAs.isEmpty else {
            throw PatchError.autoResolutionFailed("未能定位 mscorlib.dll 对应的 Il2CppCodeGenModule 结构体")
        }

        let arraySlotVAs = macho.findAllDataPointersTargeting(Set(moduleStructVAs))
        guard !arraySlotVAs.isEmpty else {
            throw PatchError.autoResolutionFailed("未能定位 codeGenModules 指针数组")
        }

        for slotVA in arraySlotVAs {
            guard let slotFileOff = macho.vaToFileOffset(slotVA) else { continue }
            for backIndex in 0..<imageCount {
                let (backBytes, backOv) = backIndex.multipliedReportingOverflow(by: 8)
                guard !backOv, slotFileOff >= backBytes else { continue }
                let arrayBaseOffset = slotFileOff - backBytes
                guard checkedTableRange(offset: arrayBaseOffset, count: imageCount, stride: 8, limit: macho.data.count) else {
                    continue
                }
                guard isCodeGenModulePointer(atFileOffset: arrayBaseOffset, macho: macho, expectedNames: expectedImageNames),
                      isCodeGenModulePointer(atFileOffset: arrayBaseOffset + (imageCount - 1) * 8, macho: macho, expectedNames: expectedImageNames) else {
                    continue
                }

                var parsed: [String: CodeGenModuleEntry] = [:]
                parsed.reserveCapacity(imageCount)
                var validCount = 0
                for idx in 0..<imageCount {
                    guard let modVA = macho.readDecodedPointerVA(atFileOffset: arrayBaseOffset + idx * 8),
                          let modOff = macho.vaToFileOffset(modVA),
                          checkedTableRange(offset: modOff, count: 3, stride: 8, limit: macho.data.count),
                          let nameVA = macho.readDecodedPointerVA(atFileOffset: modOff),
                          let name = macho.readCString(atVA: nameVA, maxLength: 256),
                          expectedImageNames.contains(name),
                          let count = safeInt(macho.readUInt64LE(atFileOffset: modOff + 8), max: 2_000_000) else {
                        validCount = 0
                        break
                    }
                    let ptrsVA = macho.readDecodedPointerVA(atFileOffset: modOff + 16) ?? 0
                    let ptrsOff = count > 0 ? (macho.vaToFileOffset(ptrsVA) ?? -1) : 0
                    if count > 0 && !checkedTableRange(offset: ptrsOff, count: count, stride: 8, limit: macho.data.count) {
                        validCount = 0
                        break
                    }
                    parsed[name] = CodeGenModuleEntry(
                        moduleName: name,
                        methodPointerCount: count,
                        methodPointersFileOffset: max(0, ptrsOff)
                    )
                    validCount += 1
                }

                if validCount == imageCount, let arrayBaseVA = macho.fileOffsetToVA(arrayBaseOffset) {
                    let codeReg = locateCodeRegistration(
                        macho: macho,
                        codeGenModulesArrayVA: arrayBaseVA,
                        imageCount: imageCount
                    )
                    return CodeGenLookup(modulesByName: parsed, codeRegistration: codeReg)
                }
            }
        }

        throw PatchError.autoResolutionFailed("找到了 mscorlib.dll 锚点，但未能验证完整的 \(imageCount) 项 Il2CppCodeGenModule 数组")
    }

    private func isCodeGenModulePointer(
        atFileOffset offset: Int,
        macho: MachOImageReader,
        expectedNames: Set<String>
    ) -> Bool {
        guard let modVA = macho.readDecodedPointerVA(atFileOffset: offset),
              let modOff = macho.vaToFileOffset(modVA),
              checkedTableRange(offset: modOff, count: 3, stride: 8, limit: macho.data.count),
              let nameVA = macho.readDecodedPointerVA(atFileOffset: modOff),
              let name = macho.readCString(atVA: nameVA, maxLength: 256) else {
            return false
        }
        return expectedNames.contains(name)
    }

    private func locateCodeRegistration(
        macho: MachOImageReader,
        codeGenModulesArrayVA: UInt64,
        imageCount: Int
    ) -> CodeRegistrationInfo? {
        let refs = macho.findAllDataPointersTargeting([codeGenModulesArrayVA])
        for refVA in refs {
            guard let refOff = macho.vaToFileOffset(refVA), refOff >= 16 * 8 else { continue }
            let countBefore = macho.readUInt64LE(atFileOffset: refOff - 8)
            guard countBefore == UInt64(imageCount) else { continue }

            for fieldsBefore in [14, 16, 13] {
                let regOff = refOff - fieldsBefore * 8
                guard checkedTableRange(offset: regOff, count: 4, stride: 8, limit: macho.data.count) else { continue }
                guard let genCount = safeInt(macho.readUInt64LE(atFileOffset: regOff + 2 * 8), max: 2_000_000),
                      genCount >= 1 else {
                    continue
                }
                guard let genPtrsVA = macho.readDecodedPointerVA(atFileOffset: regOff + 3 * 8),
                      let genPtrsOff = macho.vaToFileOffset(genPtrsVA),
                      checkedTableRange(offset: genPtrsOff, count: genCount, stride: 8, limit: macho.data.count) else {
                    continue
                }
                var checked = 0
                var validExec = true
                for i in 0..<min(genCount, 32) {
                    guard let fnVA = macho.readDecodedPointerVA(atFileOffset: genPtrsOff + i * 8) else { continue }
                    if fnVA == 0 { continue }
                    if !macho.isExecutableVA(fnVA) {
                        validExec = false
                        break
                    }
                    checked += 1
                    if checked >= 4 { break }
                }
                if validExec && checked > 0 {
                    return CodeRegistrationInfo(
                        genericMethodPointersCount: genCount,
                        genericMethodPointersFileOffset: genPtrsOff
                    )
                }
            }
        }
        return nil
    }

    // MARK: - MetadataRegistration Discovery

    private struct MetadataRegistrationInfo {
        let genericInstsCount: Int
        let genericInstsFileOffset: Int
        let genericMethodTableCount: Int
        let genericMethodTableFileOffset: Int
        let typesCount: Int
        let typesFileOffset: Int
        let methodSpecsCount: Int
        let methodSpecsFileOffset: Int
        let typeDefinitionsCount: Int
        let fieldOffsetsFileOffset: Int
        let typeDefSizesFileOffset: Int
    }

    private func locateMetadataRegistration(
        macho: MachOImageReader,
        typeDefCount: Int
    ) throws -> MetadataRegistrationInfo {
        let targetCount = UInt64(typeDefCount)
        for sec in macho.dataSections {
            guard sec.size >= 16 * 8 else { continue }
            let start = sec.fileOffset
            let limitEnd = min(sec.fileEnd, macho.data.count)
            guard limitEnd >= start + 14 * 8 else { continue }
            let end = limitEnd - 4 * 8
            var pos = start + 10 * 8
            while pos <= end {
                if macho.readUInt64LE(atFileOffset: pos) == targetCount &&
                    macho.readUInt64LE(atFileOffset: pos + 16) == targetCount {
                    let regOff = pos - 10 * 8
                    if let parsed = validateMetadataRegistration(atFileOffset: regOff, macho: macho, typeDefCount: typeDefCount) {
                        return parsed
                    }
                }
                pos += 8
            }
        }
        throw PatchError.autoResolutionFailed("未能在 UnityFramework 中定位 Il2CppMetadataRegistration（typeDefCount=\(typeDefCount)）")
    }

    private func validateMetadataRegistration(
        atFileOffset regOff: Int,
        macho: MachOImageReader,
        typeDefCount: Int
    ) -> MetadataRegistrationInfo? {
        guard checkedTableRange(offset: regOff, count: 14, stride: 8, limit: macho.data.count) else { return nil }
        guard let genericInstsCount = safeInt(macho.readUInt64LE(atFileOffset: regOff + 2 * 8), max: 5_000_000),
              let genericMethodTableCount = safeInt(macho.readUInt64LE(atFileOffset: regOff + 4 * 8), max: 5_000_000),
              let typesCount = safeInt(macho.readUInt64LE(atFileOffset: regOff + 6 * 8), max: 5_000_000),
              let methodSpecsCount = safeInt(macho.readUInt64LE(atFileOffset: regOff + 8 * 8), max: 5_000_000),
              typesCount >= typeDefCount else {
            return nil
        }

        guard let fieldOffsetsVA = macho.readDecodedPointerVA(atFileOffset: regOff + 11 * 8),
              let fieldOffsetsOff = macho.vaToFileOffset(fieldOffsetsVA),
              checkedTableRange(offset: fieldOffsetsOff, count: typeDefCount, stride: 8, limit: macho.data.count),
              let typeDefSizesVA = macho.readDecodedPointerVA(atFileOffset: regOff + 13 * 8),
              let typeDefSizesOff = macho.vaToFileOffset(typeDefSizesVA),
              checkedTableRange(offset: typeDefSizesOff, count: typeDefCount, stride: 8, limit: macho.data.count),
              let typesVA = macho.readDecodedPointerVA(atFileOffset: regOff + 7 * 8),
              let typesOff = macho.vaToFileOffset(typesVA),
              checkedTableRange(offset: typesOff, count: typesCount, stride: 8, limit: macho.data.count),
              let genericInstsVA = macho.readDecodedPointerVA(atFileOffset: regOff + 3 * 8),
              let genericInstsOff = macho.vaToFileOffset(genericInstsVA),
              checkedTableRange(offset: genericInstsOff, count: genericInstsCount, stride: 8, limit: macho.data.count),
              let genericMethodTableVA = macho.readDecodedPointerVA(atFileOffset: regOff + 5 * 8),
              let genericMethodTableOff = macho.vaToFileOffset(genericMethodTableVA),
              checkedTableRange(offset: genericMethodTableOff, count: genericMethodTableCount, stride: 16, limit: macho.data.count),
              let methodSpecsVA = macho.readDecodedPointerVA(atFileOffset: regOff + 9 * 8),
              let methodSpecsOff = macho.vaToFileOffset(methodSpecsVA),
              checkedTableRange(offset: methodSpecsOff, count: methodSpecsCount, stride: 12, limit: macho.data.count) else {
            return nil
        }

        return MetadataRegistrationInfo(
            genericInstsCount: genericInstsCount,
            genericInstsFileOffset: genericInstsOff,
            genericMethodTableCount: genericMethodTableCount,
            genericMethodTableFileOffset: genericMethodTableOff,
            typesCount: typesCount,
            typesFileOffset: typesOff,
            methodSpecsCount: methodSpecsCount,
            methodSpecsFileOffset: methodSpecsOff,
            typeDefinitionsCount: typeDefCount,
            fieldOffsetsFileOffset: fieldOffsetsOff,
            typeDefSizesFileOffset: typeDefSizesOff
        )
    }

    // MARK: - Byte-Level Struct ABI Verification (`fieldOffsets` + `typeDefinitionsSizes`)

    private struct DecodedIl2CppType {
        let dataRaw: UInt64
        let dataDecodedVA: UInt64?
        let attrs: UInt16
        let typeEnum: UInt8

        var isStaticField: Bool { (attrs & 0x0010) != 0 }
    }

    private func readIl2CppType(
        atTypeIndex typeIndex: Int,
        metaReg: MetadataRegistrationInfo,
        macho: MachOImageReader
    ) throws -> DecodedIl2CppType {
        guard typeIndex >= 0 && typeIndex < metaReg.typesCount else {
            throw PatchError.autoResolutionFailed("Il2CppType 索引越界：\(typeIndex)")
        }
        guard let typeVA = macho.readDecodedPointerVA(atFileOffset: metaReg.typesFileOffset + typeIndex * 8) else {
            throw PatchError.autoResolutionFailed("无法解码 Il2CppType[\(typeIndex)] 指针")
        }
        return try readIl2CppType(atVA: typeVA, macho: macho)
    }

    private func readIl2CppType(atVA typeVA: UInt64, macho: MachOImageReader) throws -> DecodedIl2CppType {
        guard let off = macho.vaToFileOffset(typeVA),
              checkedTableRange(offset: off, count: 12, stride: 1, limit: macho.data.count) else {
            throw PatchError.autoResolutionFailed("Il2CppType 地址越界：0x\(String(typeVA, radix: 16))")
        }
        let dataRaw = macho.readUInt64LE(atFileOffset: off)
        let dataDecodedVA = macho.readDecodedPointerVA(atFileOffset: off)
        let bits = macho.readUInt32LE(atFileOffset: off + 8)
        let attrs = UInt16(bits & 0xFFFF)
        let typeEnum = UInt8((bits >> 16) & 0xFF)
        return DecodedIl2CppType(dataRaw: dataRaw, dataDecodedVA: dataDecodedVA, attrs: attrs, typeEnum: typeEnum)
    }

    private func readCompiledFieldOffsets(
        typeDefIndex: Int,
        fieldCount: Int,
        metaReg: MetadataRegistrationInfo,
        macho: MachOImageReader
    ) -> [Int32]? {
        guard typeDefIndex >= 0 && typeDefIndex < metaReg.typeDefinitionsCount, fieldCount > 0 else {
            return nil
        }
        guard let arrVA = macho.readDecodedPointerVA(atFileOffset: metaReg.fieldOffsetsFileOffset + typeDefIndex * 8),
              let arrOff = macho.vaToFileOffset(arrVA),
              checkedTableRange(offset: arrOff, count: fieldCount, stride: 4, limit: macho.data.count) else {
            return nil
        }
        var offsets: [Int32] = []
        offsets.reserveCapacity(fieldCount)
        for i in 0..<fieldCount {
            offsets.append(macho.readInt32LE(atFileOffset: arrOff + i * 4))
        }
        return offsets
    }

    private func readCompiledInstanceSize(
        typeDefIndex: Int,
        metaReg: MetadataRegistrationInfo,
        macho: MachOImageReader
    ) -> UInt32? {
        guard typeDefIndex >= 0 && typeDefIndex < metaReg.typeDefinitionsCount else { return nil }
        guard let sizeVA = macho.readDecodedPointerVA(atFileOffset: metaReg.typeDefSizesFileOffset + typeDefIndex * 8),
              let sizeOff = macho.vaToFileOffset(sizeVA),
              checkedTableRange(offset: sizeOff, count: 16, stride: 1, limit: macho.data.count) else {
            return nil
        }
        return macho.readUInt32LE(atFileOffset: sizeOff)
    }

    private struct SDKMetaVerification {
        let fieldNames: [String]
        let exactByteOffsetsVerified: Bool
        let diagnosticNote: String
    }

    private func verifySDKMetaLayout(
        metadata: GlobalMetadataParser,
        sdkMetaType: GlobalMetadataParser.TypeLookup,
        metaReg: MetadataRegistrationInfo,
        macho: MachOImageReader
    ) throws -> SDKMetaVerification {
        let expectedNames = ["appid", "appkey", "channel", "worldid", "extension", "appcode"]
        let fields = metadata.fields(for: sdkMetaType.def)
        let compiledOffsets = readCompiledFieldOffsets(
            typeDefIndex: sdkMetaType.index,
            fieldCount: fields.count,
            metaReg: metaReg,
            macho: macho
        )

        var instanceFields: [(fieldIndexInType: Int, name: String, typeEnum: UInt8)] = []
        for (idx, field) in fields.enumerated() {
            let ilType = try readIl2CppType(atTypeIndex: field.typeIndex, metaReg: metaReg, macho: macho)
            if ilType.isStaticField { continue }
            instanceFields.append((idx, field.name, ilType.typeEnum))
        }

        guard instanceFields.count == 6 else {
            throw PatchError.autoResolutionFailed(
                "U8.SDK.SDKMeta 实例字段数量已变化（期望 6，实际 \(instanceFields.count)），已安全中止自动适配"
            )
        }
        for i in 0..<6 {
            let actual = instanceFields[i]
            guard actual.typeEnum == 0x0e else {
                throw PatchError.autoResolutionFailed(
                    "U8.SDK.SDKMeta 字段 \(actual.name) 类型不再是 System.String（type=0x\(String(actual.typeEnum, radix: 16))）"
                )
            }
            guard actual.name.lowercased() == expectedNames[i] else {
                throw PatchError.autoResolutionFailed(
                    "U8.SDK.SDKMeta 第 \(i + 1) 个字段名不匹配（期望 \(expectedNames[i])，实际 \(actual.name)）"
                )
            }
        }

        guard let compiledOffsets else {
            return SDKMetaVerification(
                fieldNames: instanceFields.map(\.name),
                exactByteOffsetsVerified: false,
                diagnosticNote: "无法读取 U8.SDK.SDKMeta 的编译期 fieldOffsets，缺少精确字节偏移证据"
            )
        }

        for i in 0..<6 {
            let actualOffset = compiledOffsets[instanceFields[i].fieldIndexInType]
            let expectedOffset = Int32(0x10 + i * 8)
            if actualOffset != expectedOffset {
                throw PatchError.autoResolutionFailed(
                    "U8.SDK.SDKMeta 字段 \(instanceFields[i].name) 编译期字节偏移不匹配（期望 0x\(String(expectedOffset, radix: 16))，实际 0x\(String(actualOffset, radix: 16))）"
                )
            }
        }

        return SDKMetaVerification(
            fieldNames: instanceFields.map(\.name),
            exactByteOffsetsVerified: true,
            diagnosticNote: "SDKMeta 字节偏移 0x10..0x38 已核验"
        )
    }

    private struct NetworkConfigVerification {
        let typeDefIndex: Int
        let stringFieldCount: Int
        let exactByteOffsetsVerified: Bool
        let diagnosticNote: String
    }

    private func verifyNetworkConfigLayout(
        metadata: GlobalMetadataParser,
        returnTypeIndex: Int,
        metaReg: MetadataRegistrationInfo,
        macho: MachOImageReader
    ) throws -> NetworkConfigVerification {
        let retType = try readIl2CppType(atTypeIndex: returnTypeIndex, metaReg: metaReg, macho: macho)
        guard retType.typeEnum == 0x11 else {
            throw PatchError.autoResolutionFailed(
                "Networker.get_networkConfig 返回类型不再是值类型结构体（type=0x\(String(retType.typeEnum, radix: 16))）"
            )
        }
        guard let structTypeDefIndex = safeInt(retType.dataRaw, max: metadata.typeDefinitions.count - 1) else {
            throw PatchError.autoResolutionFailed("无法解析 NetworkConfig 结构体类型定义索引：\(retType.dataRaw)")
        }
        let structDef = metadata.typeDefinitions[structTypeDefIndex]
        let fields = metadata.fields(for: structDef)
        let compiledOffsets = readCompiledFieldOffsets(
            typeDefIndex: structTypeDefIndex,
            fieldCount: fields.count,
            metaReg: metaReg,
            macho: macho
        )
        let compiledInstanceSize = readCompiledInstanceSize(
            typeDefIndex: structTypeDefIndex,
            metaReg: metaReg,
            macho: macho
        )

        var instanceFields: [(fieldIndexInType: Int, typeEnum: UInt8)] = []
        for (idx, field) in fields.enumerated() {
            let ilType = try readIl2CppType(atTypeIndex: field.typeIndex, metaReg: metaReg, macho: macho)
            if ilType.isStaticField { continue }
            instanceFields.append((idx, ilType.typeEnum))
        }

        guard instanceFields.count == 13,
              instanceFields[0..<12].allSatisfy({ $0.typeEnum == 0x0e }),
              instanceFields[12].typeEnum == 0x02 else {
            throw PatchError.autoResolutionFailed(
                "NetworkConfig 结构体字段布局已变化（期望 12 个 string + 1 个 bool，实际 \(instanceFields.count) 字段），需导入新版手工配置或更新桥接库"
            )
        }

        guard let compiledOffsets, let compiledInstanceSize else {
            return NetworkConfigVerification(
                typeDefIndex: structTypeDefIndex,
                stringFieldCount: 12,
                exactByteOffsetsVerified: false,
                diagnosticNote: "无法读取 NetworkConfig 的编译期 fieldOffsets 或 instance_size，缺少精确结构体大小与字节偏移证据"
            )
        }

        // In 64-bit IL2CPP, ValueType `instance_size` and `fieldOffsets` include the 16-byte `Il2CppObject` header.
        let unboxedSize = Int64(compiledInstanceSize) - 16
        guard unboxedSize == 104 else {
            throw PatchError.autoResolutionFailed(
                "NetworkConfig 编译期结构体大小已变化（期望 104 字节，实际 \(unboxedSize) 字节），与桥接 ABI 不兼容"
            )
        }
        for i in 0..<12 {
            let unboxedOff = Int(compiledOffsets[instanceFields[i].fieldIndexInType]) - 16
            guard unboxedOff == i * 8 else {
                throw PatchError.autoResolutionFailed(
                    "NetworkConfig 第 \(i + 1) 个 string 字段偏移不匹配（期望 \(i * 8)，实际 \(unboxedOff)）"
                )
            }
        }
        let devUnboxedOff = Int(compiledOffsets[instanceFields[12].fieldIndexInType]) - 16
        guard devUnboxedOff == 96 else {
            throw PatchError.autoResolutionFailed(
                "NetworkConfig dev 标记字节偏移不匹配（期望 96，实际 \(devUnboxedOff)）"
            )
        }

        return NetworkConfigVerification(
            typeDefIndex: structTypeDefIndex,
            stringFieldCount: 12,
            exactByteOffsetsVerified: true,
            diagnosticNote: "NetworkConfig 104B / dev@96 已核验"
        )
    }

    private struct ABIIssueError: Error {
        let message: String
    }

    private func verifyNetworkOverrideParamLayout(
        metadata: GlobalMetadataParser,
        method: GlobalMetadataParser.MethodDef,
        expectedNetworkConfigTypeDefIndex: Int,
        metaReg: MetadataRegistrationInfo,
        macho: MachOImageReader
    ) -> Result<Void, ABIIssueError> {
        let params = metadata.parameters(for: method)
        guard params.count == 2 else {
            return .failure(.init(message: "OverrideNetworkOptions 参数个数不是 2（实际 \(params.count)）"))
        }
        guard let param0Type = try? readIl2CppType(atTypeIndex: params[0].typeIndex, metaReg: metaReg, macho: macho) else {
            return .failure(.init(message: "无法解析 OverrideNetworkOptions 第 1 参数类型"))
        }

        // Case A: Custom ValueType struct (`struct NetworkOverride { bool enabled; NetworkConfig config; }` -> 112B, config @ +8).
        if param0Type.typeEnum == 0x11 {
            guard let tdIdx = safeInt(param0Type.dataRaw, max: metadata.typeDefinitions.count - 1) else {
                return .failure(.init(message: "OverrideNetworkOptions 参数结构体索引无效"))
            }
            let td = metadata.typeDefinitions[tdIdx]
            let fields = metadata.fields(for: td)
            var instanceFields: [(idx: Int, type: DecodedIl2CppType)] = []
            for (i, f) in fields.enumerated() {
                guard let ft = try? readIl2CppType(atTypeIndex: f.typeIndex, metaReg: metaReg, macho: macho) else {
                    return .failure(.init(message: "无法解析 NetworkOverride 字段类型"))
                }
                if ft.isStaticField { continue }
                instanceFields.append((i, ft))
            }
            guard instanceFields.count == 2,
                  instanceFields[0].type.typeEnum == 0x02,
                  instanceFields[1].type.typeEnum == 0x11,
                  safeInt(instanceFields[1].type.dataRaw, max: metadata.typeDefinitions.count - 1) == expectedNetworkConfigTypeDefIndex else {
                return .failure(.init(message: "OverrideNetworkOptions 参数结构体字段布局不再是 { bool, NetworkConfig }"))
            }
            guard let compiledOffsets = readCompiledFieldOffsets(typeDefIndex: tdIdx, fieldCount: fields.count, metaReg: metaReg, macho: macho),
                  let compiledSize = readCompiledInstanceSize(typeDefIndex: tdIdx, metaReg: metaReg, macho: macho) else {
                return .failure(.init(message: "无法读取 NetworkOverride 编译期偏移与尺寸"))
            }
            let unboxedSize = Int64(compiledSize) - 16
            let off0 = Int(compiledOffsets[instanceFields[0].idx]) - 16
            let off1 = Int(compiledOffsets[instanceFields[1].idx]) - 16
            guard unboxedSize == 112 && off0 == 0 && off1 == 8 else {
                return .failure(.init(message: "NetworkOverride ABI 不匹配（期望 size=112, enabled@0, config@8；实际 size=\(unboxedSize), @\(off0), @\(off1)）"))
            }
            return .success(())
        }

        // Case B: `System.Nullable<NetworkConfig>` (`bool hasValue` @ +0, `NetworkConfig value` @ +8 -> 112B).
        if param0Type.typeEnum == 0x15, let gcVA = param0Type.dataDecodedVA,
           let gcOff = macho.vaToFileOffset(gcVA),
           checkedTableRange(offset: gcOff, count: 3, stride: 8, limit: macho.data.count),
           let defTypeVA = macho.readDecodedPointerVA(atFileOffset: gcOff),
           let defType = try? readIl2CppType(atVA: defTypeVA, macho: macho),
           let defTdIdx = safeInt(defType.dataRaw, max: metadata.typeDefinitions.count - 1),
           let classInstVA = macho.readDecodedPointerVA(atFileOffset: gcOff + 8),
           let classInstOff = macho.vaToFileOffset(classInstVA),
           checkedTableRange(offset: classInstOff, count: 2, stride: 8, limit: macho.data.count),
           safeInt(macho.readUInt64LE(atFileOffset: classInstOff), max: 16) == 1,
           let argvVA = macho.readDecodedPointerVA(atFileOffset: classInstOff + 8),
           let argvOff = macho.vaToFileOffset(argvVA),
           checkedTableRange(offset: argvOff, count: 1, stride: 8, limit: macho.data.count),
           let arg0VA = macho.readDecodedPointerVA(atFileOffset: argvOff),
           let arg0Type = try? readIl2CppType(atVA: arg0VA, macho: macho),
           arg0Type.typeEnum == 0x11,
           safeInt(arg0Type.dataRaw, max: metadata.typeDefinitions.count - 1) == expectedNetworkConfigTypeDefIndex {
            let defTd = metadata.typeDefinitions[defTdIdx]
            let defName = metadata.string(at: defTd.nameIndex)
            let defNS = metadata.string(at: defTd.namespaceIndex)
            guard defNS == "System" && defName == "Nullable`1" else {
                return .failure(.init(message: "OverrideNetworkOptions 泛型参数不是 System.Nullable<NetworkConfig>（实际 \(defNS).\(defName)）"))
            }
            // Confirm Nullable<T> field order is (bool, T) matching `{ uint8_t enabled; pad[7]; NetworkConfig config; }`.
            let fields = metadata.fields(for: defTd)
            var instanceEnums: [UInt8] = []
            for f in fields {
                if let ft = try? readIl2CppType(atTypeIndex: f.typeIndex, metaReg: metaReg, macho: macho), !ft.isStaticField {
                    instanceEnums.append(ft.typeEnum)
                }
            }
            guard instanceEnums == [0x02, 0x13] else { // [BOOLEAN, VAR(T)]
                return .failure(.init(message: "System.Nullable<T> 字段顺序不是 (bool, T)，无法保证 112 字节覆盖布局"))
            }
            return .success(())
        }

        return .failure(.init(message: "OverrideNetworkOptions 第 1 参数不是已验证的 112 字节覆盖结构体或 Nullable<NetworkConfig>"))
    }

    // MARK: - Singleton<Networker>.get_instance Resolution

    private struct NetworkerSingletonSpec {
        let methodSpecIndex: Int
        let methodPointerRVA: UInt64
        let pointerStrategy: String
    }

    private func resolveNetworkerSingletonSpec(
        metadata: GlobalMetadataParser,
        networkerType: GlobalMetadataParser.TypeLookup,
        metaReg: MetadataRegistrationInfo,
        codeReg: CodeRegistrationInfo?,
        macho: MachOImageReader
    ) throws -> NetworkerSingletonSpec {
        let parentTypeIndex = networkerType.def.parentIndex
        guard parentTypeIndex >= 0 else {
            throw PatchError.autoResolutionFailed("Torappu.Network.Networker 缺少基类定义")
        }
        let parentType = try readIl2CppType(atTypeIndex: parentTypeIndex, metaReg: metaReg, macho: macho)
        guard parentType.typeEnum == 0x15, let genericClassVA = parentType.dataDecodedVA else {
            throw PatchError.autoResolutionFailed("Torappu.Network.Networker 的基类不再是泛型 Singleton<T>")
        }
        guard let genericClassOff = macho.vaToFileOffset(genericClassVA),
              checkedTableRange(offset: genericClassOff, count: 3, stride: 8, limit: macho.data.count),
              let genericDefTypeVA = macho.readDecodedPointerVA(atFileOffset: genericClassOff) else {
            throw PatchError.autoResolutionFailed("无法读取 Singleton<Networker> 的 Il2CppGenericClass")
        }
        let genericDefType = try readIl2CppType(atVA: genericDefTypeVA, macho: macho)
        guard let singletonTypeDefIndex = safeInt(genericDefType.dataRaw, max: metadata.typeDefinitions.count - 1) else {
            throw PatchError.autoResolutionFailed("无效的 Singleton<T> 类型定义索引：\(genericDefType.dataRaw)")
        }

        guard let getterMethod = findUniqueOptionalMethod(
            metadata,
            in: singletonTypeDefIndex,
            names: ["get_instance", "get_Instance"],
            paramCount: 0
        ) else {
            throw PatchError.autoResolutionFailed("在 Singleton<T> 上未找到唯一的 get_instance 无参方法")
        }

        var matchedSpecs: [Int] = []
        for specIdx in 0..<metaReg.methodSpecsCount {
            let off = metaReg.methodSpecsFileOffset + specIdx * 12
            let methodDefIdx = Int(macho.readInt32LE(atFileOffset: off))
            guard methodDefIdx == getterMethod.index else { continue }
            let classInstIdx = Int(macho.readInt32LE(atFileOffset: off + 4))
            guard classInstIdx >= 0 && classInstIdx < metaReg.genericInstsCount else { continue }

            guard let instVA = macho.readDecodedPointerVA(atFileOffset: metaReg.genericInstsFileOffset + classInstIdx * 8),
                  let instOff = macho.vaToFileOffset(instVA),
                  checkedTableRange(offset: instOff, count: 2, stride: 8, limit: macho.data.count),
                  safeInt(macho.readUInt64LE(atFileOffset: instOff), max: 64) == 1,
                  let argvVA = macho.readDecodedPointerVA(atFileOffset: instOff + 8),
                  let argvOff = macho.vaToFileOffset(argvVA),
                  checkedTableRange(offset: argvOff, count: 1, stride: 8, limit: macho.data.count),
                  let arg0TypeVA = macho.readDecodedPointerVA(atFileOffset: argvOff) else {
                continue
            }
            if let arg0Type = try? readIl2CppType(atVA: arg0TypeVA, macho: macho),
               arg0Type.typeEnum == 0x12,
               safeInt(arg0Type.dataRaw, max: metadata.typeDefinitions.count - 1) == networkerType.index {
                matchedSpecs.append(specIdx)
            }
        }

        guard matchedSpecs.count == 1, let specIdx = matchedSpecs.first else {
            throw PatchError.autoResolutionFailed(
                "在 methodSpecs 中找到 \(matchedSpecs.count) 个 Singleton<Networker>.get_instance 泛型实例（要求唯一）"
            )
        }

        var methodPtrRVA: UInt64 = 0
        var strategy = "跳过次级方法指针校验（可选字段置 0）"
        if let codeReg {
            for i in 0..<metaReg.genericMethodTableCount {
                let off = metaReg.genericMethodTableFileOffset + i * 16
                let genMethodIdx = Int(macho.readInt32LE(atFileOffset: off))
                if genMethodIdx == specIdx {
                    let fnIdx = Int(macho.readInt32LE(atFileOffset: off + 4))
                    if fnIdx >= 0 && fnIdx < codeReg.genericMethodPointersCount,
                       let fnVA = macho.readDecodedPointerVA(atFileOffset: codeReg.genericMethodPointersFileOffset + fnIdx * 8),
                       fnVA >= macho.textBaseVMAddr,
                       macho.isExecutableVA(fnVA) {
                        methodPtrRVA = fnVA - macho.textBaseVMAddr
                        strategy = "GenericMethodTable[\(fnIdx)]"
                    }
                    break
                }
            }
        }

        return NetworkerSingletonSpec(
            methodSpecIndex: specIdx,
            methodPointerRVA: methodPtrRVA,
            pointerStrategy: strategy
        )
    }

    // MARK: - Strict Unique Global Slot Selection

    private struct SlotResolution {
        let rva: UInt64
        let strategy: String
        let candidateCount: Int
        let issue: String?
    }

    private func resolveGlobalSlotStrict(
        label: String,
        targetTypeIndex: Int?,
        expectedToken: UInt64,
        tokenHits: [UInt64],
        helperMethodRVA: UInt64?,
        expectedUsage: UInt32,
        metadata: GlobalMetadataParser,
        metaReg: MetadataRegistrationInfo,
        macho: MachOImageReader
    ) -> SlotResolution {
        let hitSet = Set(tokenHits)

        // Strategy 1 (Gold Standard): ARM64 `ADRP + LDR/ADD` in helper method intersecting `MetadataUsage` token table.
        // MUST yield a UNIQUE intersection — never pick the first among multiple matches!
        if let methodRVA = helperMethodRVA {
            let referencedRVAs = ARM64SlotScanner.scanReferencedDataRVAs(
                macho: macho,
                methodRVA: methodRVA,
                maxInstructions: 256
            )
            let intersected = referencedRVAs.filter { hitSet.contains($0) }
            if intersected.count == 1 {
                return SlotResolution(
                    rva: intersected[0],
                    strategy: "MetadataUsage + ARM64 ADRP/LDR 唯一双重印证",
                    candidateCount: 1,
                    issue: nil
                )
            }
            if intersected.count > 1 {
                let hexList = intersected.map { IL2CPPOffsetSet.hexString($0) }.joined(separator: ", ")
                return SlotResolution(
                    rva: 0,
                    strategy: "多重候选（\(hexList)）",
                    candidateCount: intersected.count,
                    issue: "\(label) 在辅助方法 ARM64 反汇编与 MetadataUsage 交集中命中 \(intersected.count) 个候选（\(hexList)），无法唯一确认"
                )
            }

            // Strictly verified ancestor TypeInfo fallback ONLY when `tokenHits.isEmpty` and `expectedUsage == 1`:
            // decode the exact `byvalTypeIndex` in the slot and verify it is a genuine ancestor class of `targetTypeIndex`.
            if tokenHits.isEmpty, expectedUsage == 1, let childIdx = targetTypeIndex {
                let ancestorSet = ancestorTypeDefIndices(of: childIdx, metadata: metadata, metaReg: metaReg, macho: macho)
                var verifiedAncestorSlots: [UInt64] = []
                for refRVA in referencedRVAs {
                    let va = macho.textBaseVMAddr &+ refRVA
                    guard let fileOff = macho.vaToFileOffset(va),
                          checkedTableRange(offset: fileOff, count: 8, stride: 1, limit: macho.data.count) else {
                        continue
                    }
                    let rawVal = macho.readUInt64LE(atFileOffset: fileOff)
                    let usage = UInt32((rawVal & 0xE000_0000) >> 29)
                    guard (rawVal >> 32) == 0 && (rawVal & 1) == 1 && usage == 1 else { continue }
                    let decodedTypeIdx = Int((rawVal & 0x1FFF_FFFE) >> 1)
                    if let slotType = try? readIl2CppType(atTypeIndex: decodedTypeIdx, metaReg: metaReg, macho: macho),
                       (slotType.typeEnum == 0x12 || slotType.typeEnum == 0x11),
                       let slotTdIdx = safeInt(slotType.dataRaw, max: metadata.typeDefinitions.count - 1),
                       ancestorSet.contains(slotTdIdx) {
                        verifiedAncestorSlots.append(refRVA)
                    }
                }
                if verifiedAncestorSlots.count == 1 {
                    return SlotResolution(
                        rva: verifiedAncestorSlots[0],
                        strategy: "ARM64 ADRP/LDR + 已验证父类 TypeInfo 唯一槽位",
                        candidateCount: 1,
                        issue: nil
                    )
                }
                if verifiedAncestorSlots.count > 1 {
                    return SlotResolution(
                        rva: 0,
                        strategy: "多重父类候选",
                        candidateCount: verifiedAncestorSlots.count,
                        issue: "\(label) 命中多个父类 TypeInfo 候选（\(verifiedAncestorSlots.count) 个），无法唯一确认"
                    )
                }
            }
        }

        // Strategy 2: Unique v29 MetadataUsage slot across data sections.
        if tokenHits.count == 1 {
            return SlotResolution(
                rva: tokenHits[0],
                strategy: "MetadataUsage 唯一槽位",
                candidateCount: 1,
                issue: nil
            )
        }
        if tokenHits.count > 1 {
            let inData = tokenHits.filter { macho.isInPrimaryDataSection(rva: $0) }
            let hexList = tokenHits.prefix(4).map { IL2CPPOffsetSet.hexString($0) }.joined(separator: ", ")
            let hintSuffix: String
            if inData.count == 1 {
                hintSuffix = "（线索：其中 \(IL2CPPOffsetSet.hexString(inData[0])) 位于 __DATA.__data，但仅凭段位置不足以确认唯一性）"
            } else {
                hintSuffix = ""
            }
            return SlotResolution(
                rva: 0,
                strategy: "多重候选（\(tokenHits.count) 个）",
                candidateCount: tokenHits.count,
                issue: "\(label) 匹配到 \(tokenHits.count) 个候选槽位（\(hexList)）且未能通过交叉检查唯一消歧\(hintSuffix)"
            )
        }

        return SlotResolution(
            rva: 0,
            strategy: "未命中",
            candidateCount: 0,
            issue: "未能在 UnityFramework 数据段中找到 \(label) 对应的编码槽位（token=0x\(String(expectedToken, radix: 16))）"
        )
    }

    private func ancestorTypeDefIndices(
        of typeDefIndex: Int,
        metadata: GlobalMetadataParser,
        metaReg: MetadataRegistrationInfo,
        macho: MachOImageReader
    ) -> Set<Int> {
        var ancestors = Set<Int>()
        var current = typeDefIndex
        for _ in 0..<16 {
            guard current >= 0 && current < metadata.typeDefinitions.count else { break }
            let parentTypeIdx = metadata.typeDefinitions[current].parentIndex
            guard parentTypeIdx >= 0 else { break }
            guard let pType = try? readIl2CppType(atTypeIndex: parentTypeIdx, metaReg: metaReg, macho: macho),
                  pType.typeEnum == 0x12,
                  let nextTd = safeInt(pType.dataRaw, max: metadata.typeDefinitions.count - 1),
                  ancestors.insert(nextTd).inserted else {
                break
            }
            current = nextTd
        }
        return ancestors
    }

    // MARK: - Typed Unique Type / Method Lookup Helpers

    private func requireUniqueType(
        _ metadata: GlobalMetadataParser,
        namespace: String,
        name: String
    ) throws -> GlobalMetadataParser.TypeLookup {
        let matches = metadata.findTypes(namespace: namespace, name: name)
        guard matches.count == 1, let only = matches.first else {
            throw PatchError.autoResolutionFailed(
                "在 global-metadata.dat 中找到 \(matches.count) 个类型 \(namespace).\(name)（要求唯一）"
            )
        }
        return only
    }

    private func requireUniqueMethod(
        metadata: GlobalMetadataParser,
        type: GlobalMetadataParser.TypeLookup,
        name: String,
        paramCount: Int,
        metaReg: MetadataRegistrationInfo,
        macho: MachOImageReader,
        signaturePredicate: (_ returnType: DecodedIl2CppType, _ paramTypes: [DecodedIl2CppType]) -> Bool
    ) throws -> GlobalMetadataParser.MethodLookup {
        let candidates = metadata.findMethods(in: type.index, name: name, paramCount: paramCount)
        var verified: [GlobalMetadataParser.MethodLookup] = []
        for cand in candidates {
            guard let retType = try? readIl2CppType(atTypeIndex: cand.def.returnType, metaReg: metaReg, macho: macho) else {
                continue
            }
            let params = metadata.parameters(for: cand.def)
            guard params.count == paramCount else { continue }
            var pTypes: [DecodedIl2CppType] = []
            pTypes.reserveCapacity(params.count)
            var ok = true
            for p in params {
                guard let pt = try? readIl2CppType(atTypeIndex: p.typeIndex, metaReg: metaReg, macho: macho) else {
                    ok = false
                    break
                }
                pTypes.append(pt)
            }
            if ok && signaturePredicate(retType, pTypes) {
                verified.append(cand)
            }
        }
        guard verified.count == 1, let only = verified.first else {
            throw PatchError.autoResolutionFailed(
                "在 \(type.fullName) 中找到 \(verified.count) 个签名匹配的方法 \(name)（\(paramCount) 参数，候选总数 \(candidates.count)，要求唯一）"
            )
        }
        return only
    }

    private func findUniqueOptionalMethod(
        _ metadata: GlobalMetadataParser,
        in typeIndex: Int,
        names: [String],
        paramCount: Int
    ) -> GlobalMetadataParser.MethodLookup? {
        for name in names {
            let matches = metadata.findMethods(in: typeIndex, name: name, paramCount: paramCount)
            if matches.count == 1 {
                return matches[0]
            }
        }
        return nil
    }

    private func resolveMethodRVA(
        method: GlobalMetadataParser.MethodDef,
        imageName: String,
        codeGen: CodeGenLookup,
        macho: MachOImageReader
    ) throws -> UInt64 {
        guard let module = codeGen.modulesByName[imageName] else {
            throw PatchError.autoResolutionFailed("未找到模块 \(imageName) 的 CodeGenModule")
        }
        let rawTokenIndex = Int(method.token & 0x00FF_FFFF)
        let tableIndex = rawTokenIndex - 1
        guard tableIndex >= 0 && tableIndex < module.methodPointerCount else {
            throw PatchError.autoResolutionFailed("方法 \(method.name) 的 token 索引越界（\(tableIndex)/\(module.methodPointerCount)）")
        }
        let entryOff = module.methodPointersFileOffset + tableIndex * 8
        guard let va = macho.readDecodedPointerVA(atFileOffset: entryOff),
              va >= macho.textBaseVMAddr,
              macho.isExecutableVA(va) else {
            throw PatchError.autoResolutionFailed("方法 \(method.name) 的函数指针无效或不在代码段内")
        }
        return va - macho.textBaseVMAddr
    }
}

// MARK: - GlobalMetadataParser (Unity IL2CPP v27 / v29 / v31)

private final class GlobalMetadataParser {
    struct ImageDef {
        let name: String
        let typeStart: Int
        let typeCount: Int
    }

    struct TypeDef {
        let nameIndex: UInt32
        let namespaceIndex: UInt32
        let byvalTypeIndex: Int
        let parentIndex: Int
        let fieldStart: Int
        let methodStart: Int
        let methodCount: Int
        let fieldCount: Int
    }

    struct MethodDef {
        let name: String
        let declaringType: Int
        let returnType: Int
        let parameterStart: Int
        let token: UInt32
        let parameterCount: Int
    }

    struct ParameterDef {
        let name: String
        let token: UInt32
        let typeIndex: Int
    }

    struct FieldDef {
        let name: String
        let typeIndex: Int
        let token: UInt32
    }

    struct TypeLookup {
        let index: Int
        let def: TypeDef
        let imageName: String
        let fullName: String
    }

    struct MethodLookup {
        let index: Int
        let def: MethodDef
    }

    private let data: Data
    let version: Int
    private let stringOffset: Int
    private let stringSize: Int
    private let methodsOffset: Int
    private let methodsCount: Int
    private let methodStride: Int
    private let parametersOffset: Int
    private let parametersCount: Int
    private let fieldsOffset: Int
    private let fieldsCount: Int
    let images: [ImageDef]
    let typeDefinitions: [TypeDef]
    private let typeToImageName: [String]

    init(data: Data) throws {
        self.data = data
        guard data.count >= 0xB8 else {
            throw PatchError.autoResolutionFailed("global-metadata.dat 文件头被截断")
        }
        let magic = Self.readUInt32LE(data, at: 0)
        guard magic == 0xFAB1_1BAF else {
            throw PatchError.autoResolutionFailed(
                String(format: "global-metadata.dat 头部魔数非标准明文（0x%08X），暂不支持自动解析", magic)
            )
        }
        let ver = Int(Self.readInt32LE(data, at: 4))
        guard ver == 27 || ver == 29 || ver == 31 else {
            throw PatchError.autoResolutionFailed("暂不支持 IL2CPP 元数据版本 v\(ver)（当前自动解析支持 v27 / v29 / v31）")
        }
        self.version = ver
        self.methodStride = (ver >= 31) ? 36 : 32

        func readSection(offsetAt: Int, sizeAt: Int, label: String, allowEmpty: Bool = false) throws -> (Int, Int) {
            let offU = UInt64(Self.readUInt32LE(data, at: offsetAt))
            let sizeI = Int(Self.readInt32LE(data, at: sizeAt))
            guard sizeI >= 0, (allowEmpty || sizeI > 0),
                  let off = Int(exactly: offU),
                  off >= 0, off <= data.count, sizeI <= data.count - off else {
                throw PatchError.autoResolutionFailed("global-metadata.dat 表区间越界（\(label)）")
            }
            return (off, sizeI)
        }

        let (strOff, strSize) = try readSection(offsetAt: 0x18, sizeAt: 0x1C, label: "string")
        let (methOff, methSize) = try readSection(offsetAt: 0x30, sizeAt: 0x34, label: "methods", allowEmpty: true)
        let (paramOff, paramSize) = try readSection(offsetAt: 0x58, sizeAt: 0x5C, label: "parameters", allowEmpty: true)
        let (fldOff, fldSize) = try readSection(offsetAt: 0x60, sizeAt: 0x64, label: "fields", allowEmpty: true)
        let (tdOff, tdSize) = try readSection(offsetAt: 0xA0, sizeAt: 0xA4, label: "typeDefinitions")
        let (imgOff, imgSize) = try readSection(offsetAt: 0xA8, sizeAt: 0xAC, label: "images")

        self.stringOffset = strOff
        self.stringSize = strSize
        self.methodsOffset = methOff
        self.methodsCount = methSize / methodStride
        self.parametersOffset = paramOff
        self.parametersCount = paramSize / 12
        self.fieldsOffset = fldOff
        self.fieldsCount = fldSize / 12

        let typeStride = 88
        let typeCount = tdSize / typeStride
        var parsedTypes: [TypeDef] = []
        parsedTypes.reserveCapacity(typeCount)
        for i in 0..<typeCount {
            let base = tdOff + i * typeStride
            parsedTypes.append(
                TypeDef(
                    nameIndex: Self.readUInt32LE(data, at: base + 0x00),
                    namespaceIndex: Self.readUInt32LE(data, at: base + 0x04),
                    byvalTypeIndex: Int(Self.readInt32LE(data, at: base + 0x08)),
                    parentIndex: Int(Self.readInt32LE(data, at: base + 0x10)),
                    fieldStart: Int(Self.readInt32LE(data, at: base + 0x20)),
                    methodStart: Int(Self.readInt32LE(data, at: base + 0x24)),
                    methodCount: Int(Self.readUInt16LE(data, at: base + 0x40)),
                    fieldCount: Int(Self.readUInt16LE(data, at: base + 0x44))
                )
            )
        }
        self.typeDefinitions = parsedTypes

        let imageStride = 40
        let imageCount = imgSize / imageStride
        var parsedImages: [ImageDef] = []
        parsedImages.reserveCapacity(imageCount)
        var typeImageMap = Array(repeating: "", count: typeCount)

        for i in 0..<imageCount {
            let base = imgOff + i * imageStride
            let nameIdx = Self.readUInt32LE(data, at: base + 0x00)
            let typeStart = Int(Self.readInt32LE(data, at: base + 0x08))
            let imgTypeCountU = Self.readUInt32LE(data, at: base + 0x0C)
            let imgName = Self.readString(data: data, tableOffset: strOff, tableSize: strSize, index: nameIdx)
            let imgTypeCount = Int(min(UInt64(imgTypeCountU), UInt64(typeCount)))
            parsedImages.append(ImageDef(name: imgName, typeStart: typeStart, typeCount: imgTypeCount))
            if typeStart >= 0 && typeStart <= typeCount && imgTypeCount <= typeCount - typeStart {
                for t in typeStart..<(typeStart + imgTypeCount) {
                    typeImageMap[t] = imgName
                }
            }
        }
        self.images = parsedImages
        self.typeToImageName = typeImageMap
    }

    func string(at index: UInt32) -> String {
        Self.readString(data: data, tableOffset: stringOffset, tableSize: stringSize, index: index)
    }

    func findTypes(namespace: String, name: String) -> [TypeLookup] {
        var out: [TypeLookup] = []
        for (idx, td) in typeDefinitions.enumerated() {
            if string(at: td.nameIndex) == name && string(at: td.namespaceIndex) == namespace {
                let full = namespace.isEmpty ? name : "\(namespace).\(name)"
                out.append(TypeLookup(index: idx, def: td, imageName: typeToImageName[idx], fullName: full))
            }
        }
        return out
    }

    func findMethods(in typeIndex: Int, name: String, paramCount: Int?) -> [MethodLookup] {
        guard typeIndex >= 0 && typeIndex < typeDefinitions.count else { return [] }
        let td = typeDefinitions[typeIndex]
        guard td.methodStart >= 0 && td.methodCount > 0 else { return [] }

        var matches: [MethodLookup] = []
        for i in 0..<td.methodCount {
            let methodIdx = td.methodStart + i
            guard methodIdx >= 0 && methodIdx < methodsCount,
                  let md = readMethodDef(at: methodIdx) else { continue }
            guard md.name == name else { continue }
            if let expectedParams = paramCount, md.parameterCount != expectedParams {
                continue
            }
            matches.append(MethodLookup(index: methodIdx, def: md))
        }
        return matches
    }

    func parameters(for md: MethodDef) -> [ParameterDef] {
        guard md.parameterCount > 0 else { return [] }
        guard md.parameterStart >= 0,
              md.parameterStart <= parametersCount,
              md.parameterCount <= parametersCount - md.parameterStart else {
            return []
        }
        var out: [ParameterDef] = []
        out.reserveCapacity(md.parameterCount)
        for i in 0..<md.parameterCount {
            let base = parametersOffset + (md.parameterStart + i) * 12
            guard base >= 0 && base <= data.count - 12 else { break }
            let nameIdx = Self.readUInt32LE(data, at: base + 0)
            let token = Self.readUInt32LE(data, at: base + 4)
            let typeIdx = Int(Self.readInt32LE(data, at: base + 8))
            out.append(ParameterDef(name: string(at: nameIdx), token: token, typeIndex: typeIdx))
        }
        return out
    }

    func fields(for td: TypeDef) -> [FieldDef] {
        guard td.fieldCount > 0 else { return [] }
        guard td.fieldStart >= 0,
              td.fieldStart <= fieldsCount,
              td.fieldCount <= fieldsCount - td.fieldStart else {
            return []
        }
        var out: [FieldDef] = []
        out.reserveCapacity(td.fieldCount)
        for i in 0..<td.fieldCount {
            let base = fieldsOffset + (td.fieldStart + i) * 12
            guard base >= 0 && base <= data.count - 12 else { break }
            let nameIdx = Self.readUInt32LE(data, at: base + 0)
            let typeIdx = Int(Self.readInt32LE(data, at: base + 4))
            let token = Self.readUInt32LE(data, at: base + 8)
            out.append(FieldDef(name: string(at: nameIdx), typeIndex: typeIdx, token: token))
        }
        return out
    }

    private func readMethodDef(at index: Int) -> MethodDef? {
        guard index >= 0 && index < methodsCount else { return nil }
        let base = methodsOffset + index * methodStride
        guard base >= 0 && base <= data.count - methodStride else { return nil }
        let nameIdx = Self.readUInt32LE(data, at: base + 0x00)
        let declaringType = Int(Self.readInt32LE(data, at: base + 0x04))
        let returnType = Int(Self.readInt32LE(data, at: base + 0x08))
        let shift = (version >= 31) ? 4 : 0
        let paramStart = Int(Self.readInt32LE(data, at: base + 0x0C + shift))
        let token = Self.readUInt32LE(data, at: base + 0x14 + shift)
        let paramCount = Int(Self.readUInt16LE(data, at: base + 0x1E + shift))
        return MethodDef(
            name: string(at: nameIdx),
            declaringType: declaringType,
            returnType: returnType,
            parameterStart: paramStart,
            token: token,
            parameterCount: paramCount
        )
    }

    private static func readString(data: Data, tableOffset: Int, tableSize: Int, index: UInt32) -> String {
        let idxU = UInt64(index)
        guard idxU < UInt64(tableSize), let idx = Int(exactly: idxU) else { return "" }
        let start = tableOffset + idx
        let limit = min(tableOffset + tableSize, data.count)
        guard start >= tableOffset && start < limit else { return "" }
        var end = start
        let baseIdx = data.startIndex
        while end < limit && data[baseIdx + end] != 0 {
            end += 1
        }
        return String(decoding: data[(baseIdx + start)..<(baseIdx + end)], as: UTF8.self)
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }

    private static func readInt32LE(_ data: Data, at offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32LE(data, at: offset))
    }
}

// MARK: - MachOImageReader (64-bit arm64 + LC_DYLD_CHAINED_FIXUPS, Overflow-Safe)

private final class MachOImageReader {
    struct Section {
        let segName: String
        let sectName: String
        let vmAddr: UInt64
        let size: Int
        let fileOffset: Int
        let flags: UInt32

        var vmEnd: UInt64 { vmAddr &+ UInt64(size) }
        var fileEnd: Int { fileOffset + size }
        var isZeroFill: Bool { (flags & 0xFF) == 1 || (flags & 0xFF) == 0x0B || (flags & 0xFF) == 0x0C }
        var isExecutable: Bool { (flags & 0x8000_0000) != 0 || (flags & 0x0000_0400) != 0 || sectName == "__text" }
    }

    struct Segment {
        let name: String
        let vmAddr: UInt64
        let vmSize: UInt64
        let fileOffset: Int
        let fileSize: Int
        var chainedPointerFormat: UInt16?
    }

    let data: Data
    let textBaseVMAddr: UInt64
    let uuid: String?
    let segments: [Segment]
    let sections: [Section]
    let dataSections: [Section]
    let readableSections: [Section]
    let execSections: [Section]
    let primaryTextSection: Section?

    private static let mhMagic64LE: UInt32 = 0xfeed_facf
    private static let lcSegment64: UInt32 = 0x19
    private static let lcUUID: UInt32 = 0x1b
    private static let lcDyldChainedFixups: UInt32 = 0x8000_0034

    init(data: Data) throws {
        self.data = data
        guard data.count >= 32, Self.readUInt32LE(data, at: 0) == Self.mhMagic64LE else {
            throw PatchError.autoResolutionFailed("UnityFramework 不是单架构 64 位 Mach-O 文件")
        }

        let ncmdsU = Self.readUInt32LE(data, at: 16)
        let sizeofcmdsU = Self.readUInt32LE(data, at: 20)
        guard let ncmds = Int(exactly: ncmdsU),
              let sizeofcmds = Int(exactly: sizeofcmdsU),
              sizeofcmds <= data.count - 32,
              ncmds <= sizeofcmds / 8 else {
            throw PatchError.autoResolutionFailed("UnityFramework Load Commands 区域越界")
        }
        let cmdsEnd = 32 + sizeofcmds

        var parsedSegments: [Segment] = []
        var parsedSections: [Section] = []
        var foundUUID: String?
        var textBase: UInt64 = 0
        var hasTextSeg = false
        var chainedFixupsOff: Int?
        var chainedFixupsSize: Int?

        var cursor = 32
        for _ in 0..<ncmds {
            guard cursor <= cmdsEnd - 8 else { break }
            let cmd = Self.readUInt32LE(data, at: cursor)
            let cmdsizeU = Self.readUInt32LE(data, at: cursor + 4)
            guard let cmdsize = Int(exactly: cmdsizeU),
                  cmdsize >= 8,
                  cmdsize <= cmdsEnd - cursor else {
                throw PatchError.autoResolutionFailed("UnityFramework 存在损坏的 Load Command 尺寸")
            }

            if cmd == Self.lcSegment64 && cmdsize >= 72 {
                let segName = Self.readFixedCString(data, at: cursor + 8, maxLen: 16)
                let vmAddr = Self.readUInt64LE(data, at: cursor + 24)
                let vmSize = Self.readUInt64LE(data, at: cursor + 32)
                let fileOffU = Self.readUInt64LE(data, at: cursor + 40)
                let fileSizeU = Self.readUInt64LE(data, at: cursor + 48)
                let nsectsU = Self.readUInt32LE(data, at: cursor + 64)

                guard let fileOff = Int(exactly: fileOffU),
                      let fileSize = Int(exactly: fileSizeU),
                      fileOff >= 0, fileOff <= data.count, fileSize >= 0, fileSize <= data.count - fileOff,
                      let nsects = Int(exactly: nsectsU),
                      nsects <= (cmdsize - 72) / 80 else {
                    throw PatchError.autoResolutionFailed("UnityFramework LC_SEGMENT_64 段偏移或节数量越界（\(segName)）")
                }

                if segName == "__TEXT" {
                    textBase = vmAddr
                    hasTextSeg = true
                }
                parsedSegments.append(
                    Segment(name: segName, vmAddr: vmAddr, vmSize: vmSize, fileOffset: fileOff, fileSize: fileSize, chainedPointerFormat: nil)
                )

                var secCursor = cursor + 72
                for _ in 0..<nsects {
                    guard secCursor <= cursor + cmdsize - 80 else { break }
                    let sectName = Self.readFixedCString(data, at: secCursor, maxLen: 16)
                    let sSegName = Self.readFixedCString(data, at: secCursor + 16, maxLen: 16)
                    let sAddr = Self.readUInt64LE(data, at: secCursor + 32)
                    let sSizeU = Self.readUInt64LE(data, at: secCursor + 40)
                    let sOffsetU = UInt64(Self.readUInt32LE(data, at: secCursor + 48))
                    let sFlags = Self.readUInt32LE(data, at: secCursor + 64)
                    let isZeroFill = (sFlags & 0xFF) == 1 || (sFlags & 0xFF) == 0x0B || (sFlags & 0xFF) == 0x0C

                    if !isZeroFill,
                       let sOffset = Int(exactly: sOffsetU),
                       let sSize = Int(exactly: sSizeU),
                       sOffset >= 0, sOffset <= data.count, sSize >= 0, sSize <= data.count - sOffset {
                        parsedSections.append(
                            Section(segName: sSegName, sectName: sectName, vmAddr: sAddr, size: sSize, fileOffset: sOffset, flags: sFlags)
                        )
                    }
                    secCursor += 80
                }
            } else if cmd == Self.lcUUID && cmdsize >= 24 {
                let s = data.startIndex + cursor + 8
                let b = Array(data[s..<(s + 16)])
                let u = UUID(uuid: (
                    b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                    b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
                ))
                foundUUID = u.uuidString.lowercased()
            } else if cmd == Self.lcDyldChainedFixups && cmdsize >= 16 {
                let fOff = Int(exactly: Self.readUInt32LE(data, at: cursor + 8))
                let fSize = Int(exactly: Self.readUInt32LE(data, at: cursor + 12))
                if let fOff, let fSize, fOff >= 0, fSize >= 0, fOff <= data.count, fSize <= data.count - fOff {
                    chainedFixupsOff = fOff
                    chainedFixupsSize = fSize
                }
            }

            cursor += cmdsize
        }

        guard hasTextSeg else {
            throw PatchError.autoResolutionFailed("UnityFramework 缺少 __TEXT 段")
        }

        // Parse `LC_DYLD_CHAINED_FIXUPS` pointer formats per segment safely.
        if let fixOff = chainedFixupsOff, let fixSize = chainedFixupsSize, fixSize >= 16 {
            let fixEnd = fixOff + fixSize
            if let startsRel = Int(exactly: Self.readUInt32LE(data, at: fixOff + 4)),
               startsRel >= 0, startsRel <= fixSize - 4 {
                let imgStartsPos = fixOff + startsRel
                if let segCount = Int(exactly: Self.readUInt32LE(data, at: imgStartsPos)),
                   segCount <= (fixEnd - imgStartsPos - 4) / 4 {
                    for i in 0..<segCount {
                        guard let segInfoRel = Int(exactly: Self.readUInt32LE(data, at: imgStartsPos + 4 + i * 4)),
                              segInfoRel > 0, segInfoRel <= fixEnd - imgStartsPos - 16 else {
                            continue
                        }
                        let segInfoPos = imgStartsPos + segInfoRel
                        let pointerFormat = Self.readUInt16LE(data, at: segInfoPos + 6)
                        let segFileOffU = Self.readUInt64LE(data, at: segInfoPos + 8)
                        if let segFileOff = Int(exactly: segFileOffU),
                           let idx = parsedSegments.firstIndex(where: { $0.fileOffset == segFileOff && $0.fileSize > 0 }) {
                            parsedSegments[idx].chainedPointerFormat = pointerFormat
                        } else if i < parsedSegments.count {
                            parsedSegments[i].chainedPointerFormat = pointerFormat
                        }
                    }
                }
            }
        }

        self.textBaseVMAddr = textBase
        self.uuid = foundUUID
        self.segments = parsedSegments
        self.sections = parsedSections
        self.primaryTextSection = parsedSections.first { $0.segName == "__TEXT" && $0.sectName == "__text" }
        self.execSections = parsedSections.filter { !$0.isZeroFill && $0.size > 0 && $0.isExecutable }
        self.dataSections = parsedSections.filter { sec in
            guard !sec.isZeroFill && sec.size >= 8 && sec.fileOffset > 0 && sec.fileEnd <= data.count else {
                return false
            }
            return sec.segName == "__DATA"
                || sec.segName == "__DATA_CONST"
                || sec.segName == "__AUTH"
                || sec.segName == "__AUTH_CONST"
                || sec.sectName == "__const"
                || sec.sectName == "__data"
        }
        self.readableSections = parsedSections.filter { sec in
            !sec.isZeroFill && sec.size > 0 && sec.fileOffset > 0 && sec.fileEnd <= data.count
        }
    }

    func computeTextSectionDigest() -> (size: UInt64?, sha256: String?) {
        guard let sec = primaryTextSection,
              sec.fileOffset >= 0,
              sec.fileEnd <= data.count else {
            return (nil, nil)
        }
        let slice = data[(data.startIndex + sec.fileOffset)..<(data.startIndex + sec.fileEnd)]
        return (UInt64(sec.size), SHA256.hash(data: slice).hexString)
    }

    func vaToFileOffset(_ va: UInt64) -> Int? {
        for seg in segments where seg.fileSize > 0 {
            let segFileSizeU = UInt64(seg.fileSize)
            if va >= seg.vmAddr && (va - seg.vmAddr) < segFileSizeU {
                let delta = Int(va - seg.vmAddr)
                let off = seg.fileOffset + delta
                if off >= 0 && off < data.count {
                    return off
                }
            }
        }
        return nil
    }

    func fileOffsetToVA(_ fileOffset: Int) -> UInt64? {
        for seg in segments where seg.fileSize > 0 {
            if fileOffset >= seg.fileOffset && fileOffset < seg.fileOffset + seg.fileSize {
                return seg.vmAddr &+ UInt64(fileOffset - seg.fileOffset)
            }
        }
        return nil
    }

    func isExecutableVA(_ va: UInt64) -> Bool {
        execSections.contains { va >= $0.vmAddr && (va - $0.vmAddr) < UInt64($0.size) }
    }

    func isInPrimaryDataSection(rva: UInt64) -> Bool {
        let va = textBaseVMAddr &+ rva
        return dataSections.contains {
            $0.segName == "__DATA" && $0.sectName == "__data" && va >= $0.vmAddr && (va - $0.vmAddr) < UInt64($0.size)
        }
    }

    func isDataVA(_ va: UInt64) -> Bool {
        dataSections.contains { va >= $0.vmAddr && (va - $0.vmAddr) < UInt64($0.size) }
    }

    func pointerFormat(atFileOffset offset: Int) -> UInt16? {
        for seg in segments where seg.fileSize > 0 {
            if offset >= seg.fileOffset && offset < seg.fileOffset + seg.fileSize {
                return seg.chainedPointerFormat
            }
        }
        return nil
    }

    func readDecodedPointerVA(atFileOffset offset: Int) -> UInt64? {
        guard offset >= 0 && offset <= data.count - 8 else { return nil }
        let raw = readUInt64LE(atFileOffset: offset)
        if raw == 0 { return nil }

        if let fmt = pointerFormat(atFileOffset: offset) {
            switch fmt {
            case 6: // DYLD_CHAINED_PTR_64_OFFSET
                if (raw & (1 << 63)) != 0 { return nil }
                return textBaseVMAddr &+ (raw & 0x0000_000F_FFFF_FFFF)
            case 2: // DYLD_CHAINED_PTR_64
                if (raw & (1 << 63)) != 0 { return nil }
                return raw & 0x0000_000F_FFFF_FFFF
            case 1: // DYLD_CHAINED_PTR_ARM64E
                if (raw & (1 << 62)) != 0 { return nil }
                if (raw & (1 << 63)) != 0 { return textBaseVMAddr &+ (raw & 0xFFFF_FFFF) }
                return raw & 0x0000_07FF_FFFF_FFFF
            case 7, 9, 12: // DYLD_CHAINED_PTR_ARM64E_OFFSET / USERLAND / USERLAND24
                if (raw & (1 << 62)) != 0 { return nil }
                if (raw & (1 << 63)) != 0 { return textBaseVMAddr &+ (raw & 0xFFFF_FFFF) }
                return textBaseVMAddr &+ (raw & 0x0000_0003_FFFF_FFFF)
            default:
                break
            }
        }

        if vaToFileOffset(raw) != nil {
            return raw
        }
        if raw > textBaseVMAddr &+ 0xFFFF_FFFF && (raw & (1 << 63)) == 0 {
            let stripped = (raw & 0x0000_000F_FFFF_FFFF) &+ textBaseVMAddr
            if vaToFileOffset(stripped) != nil {
                return stripped
            }
        }
        return nil
    }

    func findAllBytesInReadableSections(_ needle: Data) -> [UInt64] {
        var results: [UInt64] = []
        for sec in readableSections {
            let startIdx = data.startIndex + sec.fileOffset
            let endIdx = startIdx + sec.size
            var searchStart = startIdx
            while searchStart < endIdx, let range = data.range(of: needle, options: [], in: searchStart..<endIdx) {
                let rel = range.lowerBound - startIdx
                results.append(sec.vmAddr &+ UInt64(rel))
                searchStart = range.upperBound
            }
        }
        return results
    }

    func findAllDataPointersTargeting(_ targets: Set<UInt64>) -> [UInt64] {
        guard !targets.isEmpty else { return [] }
        var hits: [UInt64] = []
        for sec in dataSections {
            let fmt = pointerFormat(atFileOffset: sec.fileOffset)
            let count = sec.size / 8
            let base = sec.fileOffset
            for i in 0..<count {
                let off = base + i * 8
                let raw = readUInt64LE(atFileOffset: off)
                if raw == 0 { continue }
                let decoded: UInt64?
                if let fmt {
                    decoded = decodePointerFast(raw: raw, format: fmt)
                } else {
                    decoded = decodePointerUnchained(raw: raw)
                }
                if let va = decoded, targets.contains(va) {
                    hits.append(sec.vmAddr &+ UInt64(i * 8))
                }
            }
        }
        return hits
    }

    func scanDataSectionsForRawUInt64s(targets: Set<UInt64>) -> [UInt64: [UInt64]] {
        var results: [UInt64: [UInt64]] = [:]
        guard !targets.isEmpty else { return results }
        for sec in dataSections {
            let count = sec.size / 8
            let base = sec.fileOffset
            for i in 0..<count {
                let val = readUInt64LE(atFileOffset: base + i * 8)
                if targets.contains(val) {
                    let va = sec.vmAddr &+ UInt64(i * 8)
                    let rva = va >= textBaseVMAddr ? (va - textBaseVMAddr) : va
                    results[val, default: []].append(rva)
                }
            }
        }
        return results
    }

    @inline(__always)
    private func decodePointerFast(raw: UInt64, format: UInt16) -> UInt64? {
        switch format {
        case 6:
            if (raw & (1 << 63)) != 0 { return nil }
            return textBaseVMAddr &+ (raw & 0x0000_000F_FFFF_FFFF)
        case 2:
            if (raw & (1 << 63)) != 0 { return nil }
            return raw & 0x0000_000F_FFFF_FFFF
        case 1:
            if (raw & (1 << 62)) != 0 { return nil }
            if (raw & (1 << 63)) != 0 { return textBaseVMAddr &+ (raw & 0xFFFF_FFFF) }
            return raw & 0x0000_07FF_FFFF_FFFF
        case 7, 9, 12:
            if (raw & (1 << 62)) != 0 { return nil }
            if (raw & (1 << 63)) != 0 { return textBaseVMAddr &+ (raw & 0xFFFF_FFFF) }
            return textBaseVMAddr &+ (raw & 0x0000_0003_FFFF_FFFF)
        default:
            return decodePointerUnchained(raw: raw)
        }
    }

    @inline(__always)
    private func decodePointerUnchained(raw: UInt64) -> UInt64? {
        if raw >= textBaseVMAddr && raw <= textBaseVMAddr &+ 0xFFFF_FFFF {
            return raw
        }
        if (raw & (1 << 63)) == 0 {
            return textBaseVMAddr &+ (raw & 0x0000_000F_FFFF_FFFF)
        }
        return nil
    }

    func readCString(atVA va: UInt64, maxLength: Int) -> String? {
        guard let off = vaToFileOffset(va) else { return nil }
        let limit = min(off + maxLength, data.count)
        let baseIdx = data.startIndex
        var end = off
        while end < limit && data[baseIdx + end] != 0 {
            end += 1
        }
        guard end > off && end < limit else { return nil }
        return String(decoding: data[(baseIdx + off)..<(baseIdx + end)], as: UTF8.self)
    }

    @inline(__always)
    func readUInt32LE(atFileOffset offset: Int) -> UInt32 {
        Self.readUInt32LE(data, at: offset)
    }

    @inline(__always)
    func readInt32LE(atFileOffset offset: Int) -> Int32 {
        Int32(bitPattern: Self.readUInt32LE(data, at: offset))
    }

    @inline(__always)
    func readUInt64LE(atFileOffset offset: Int) -> UInt64 {
        Self.readUInt64LE(data, at: offset)
    }

    private static func readFixedCString(_ data: Data, at offset: Int, maxLen: Int) -> String {
        let baseIdx = data.startIndex + offset
        var len = 0
        while len < maxLen && data[baseIdx + len] != 0 {
            len += 1
        }
        return String(decoding: data[baseIdx..<(baseIdx + len)], as: UTF8.self)
    }

    @inline(__always)
    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
    }

    @inline(__always)
    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }

    @inline(__always)
    private static func readUInt64LE(_ data: Data, at offset: Int) -> UInt64 {
        let lo = UInt64(readUInt32LE(data, at: offset))
        let hi = UInt64(readUInt32LE(data, at: offset + 4))
        return lo | (hi << 32)
    }
}

// MARK: - ARM64 ADRP + LDR / ADD Slot Disassembler

private enum ARM64SlotScanner {
    static func scanReferencedDataRVAs(
        macho: MachOImageReader,
        methodRVA: UInt64,
        maxInstructions: Int = 256
    ) -> [UInt64] {
        let startVA = macho.textBaseVMAddr &+ methodRVA
        guard let startOff = macho.vaToFileOffset(startVA) else { return [] }

        var pageRegs: [Int: UInt64] = [:]
        var found: [UInt64] = []
        var seen = Set<UInt64>()

        for step in 0..<maxInstructions {
            let off = startOff + step * 4
            guard off <= macho.data.count - 4 else { break }
            let insn = macho.readUInt32LE(atFileOffset: off)
            let pc = startVA &+ UInt64(step * 4)

            // Stop at RET / RETAA / RETAB
            if insn == 0xD65F_03C0 || insn == 0xD65F_0BFF || insn == 0xD65F_0FFF {
                break
            }

            // ADRP Xd, #imm
            if (insn & 0x9F00_0000) == 0x9000_0000 {
                let rd = Int(insn & 0x1F)
                let immlo = (insn >> 29) & 0x3
                let immhi = (insn >> 5) & 0x7_FFFF
                let imm21 = (immhi << 2) | immlo
                let signedImm21: Int64 = (imm21 & 0x10_0000) != 0
                    ? Int64(imm21) - (1 << 21)
                    : Int64(imm21)
                let page = (pc & ~0xFFF) &+ UInt64(bitPattern: signedImm21 << 12)
                if rd != 31 {
                    pageRegs[rd] = page
                }
                continue
            }

            // LDR Xt, [Xn, #uimm12 * 8]
            if (insn & 0xFFC0_0000) == 0xF940_0000 {
                let rt = Int(insn & 0x1F)
                let rn = Int((insn >> 5) & 0x1F)
                let imm12 = UInt64((insn >> 10) & 0xFFF) * 8
                if let page = pageRegs[rn] {
                    let targetVA = page &+ imm12
                    if macho.isDataVA(targetVA) && targetVA >= macho.textBaseVMAddr {
                        let rva = targetVA - macho.textBaseVMAddr
                        if seen.insert(rva).inserted {
                            found.append(rva)
                        }
                    }
                }
                if rt != 31 {
                    pageRegs.removeValue(forKey: rt)
                }
                continue
            }

            // ADD Xd, Xn, #uimm12
            if (insn & 0xFF80_0000) == 0x9100_0000 {
                let rd = Int(insn & 0x1F)
                let rn = Int((insn >> 5) & 0x1F)
                let shift = (insn >> 22) & 1
                let imm12 = UInt64((insn >> 10) & 0xFFF) << (shift == 1 ? 12 : 0)
                if let page = pageRegs[rn] {
                    let targetVA = page &+ imm12
                    if macho.isDataVA(targetVA) && targetVA >= macho.textBaseVMAddr {
                        let rva = targetVA - macho.textBaseVMAddr
                        if seen.insert(rva).inserted {
                            found.append(rva)
                        }
                    }
                    if rd != 31 {
                        pageRegs[rd] = targetVA
                    }
                } else if rd != 31 {
                    pageRegs.removeValue(forKey: rd)
                }
                continue
            }

            if (insn & 0xFC00_0000) == 0x9400_0000 || (insn & 0xFFFF_FC1F) == 0xD63F_0000 {
                for r in 0...18 {
                    pageRegs.removeValue(forKey: r)
                }
            }
        }

        return found
    }
}
