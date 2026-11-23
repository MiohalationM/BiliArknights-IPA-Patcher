# 手工适配配置规范（`RuntimeOffsetProfile`）

当游戏大版本更新后，如果不想重新编译或更新「方舟补丁工具」App，只需准备一份几 KB 的手工适配配置文件（`.json` 或 `.plist`），导入到 App 的 **「适配配置管理」** 中即可直接生效。

> 匹配优先级：**① 已导入的手工配置** → **② 内置已验证基准（2.7.91）** → **③ 本机自动定位（IL2CPP）**。

---

## 一、导入方式

1. **在 App 内导入**：首页 → 修补选项 → **「适配配置管理」** → **「从「文件」导入手工配置（.json / .plist）」**。
2. **从「文件」直接打开**：在 iOS「文件」App 中点击 `.json` 或 `.plist` 配置文件 → 分享 / 打开方式选择 **「方舟补丁工具」**，App 会自动校验并入库。

导入后的配置保存在沙盒 `Application Support/CustomProfiles/`（已排除 iCloud 备份），支持随时查看和删除；导入同一 `(version, build, unityUUID)` 时会自动覆盖旧配置。

---

## 二、JSON 配置文件格式（`schema = 1`）

数值偏移字段同时兼容 **十六进制字符串（推荐，如 `"0xb9a5e38"`）** 与 **十进制整数**。

```json
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
  "notes": "可选备注信息"
}
```

> 也支持直接导入与运行时一致的 XML / Binary 格式 `ABRuntimeProfile.plist` 文件（顶级键与上方 JSON 同名；若省略 `schema` / `bundleID` / `name` / `revision`，解析器会自动补全默认值）。

---

## 三、顶层字段说明

| 字段 | 必需 | 说明 |
| --- | --- | --- |
| `schema` | 否（默认 `1`） | 仅支持 `1` |
| `name` | 否 | 在 App 列表中显示的友好名称 |
| `revision` | 否 | 写入修补后 `Info.plist` 的 `ABPackagingRevision` 与 `ABRuntimeProfile.plist` |
| `bundleID` | 否（默认 `com.hypergryph.arknights`） | 目标应用 Bundle ID |
| `version` | **是** | 宿主 `CFBundleShortVersionString`（如 `"2.8.0"`） |
| `build` | **是** | 宿主 `CFBundleVersion`（如 `"80"`，字符串或整数均可） |
| `unityUUID` | **是** | 目标 `UnityFramework` 的 Mach-O `LC_UUID`（标准 UUID 字符串，不区分大小写） |
| `unityTextSize` | 否（需与 `unityTextSHA256` 成对） | `UnityFramework` `__TEXT.__text` 节大小。与 `unityTextSHA256` 必须 **同时提供** 或 **同时省略/置空**；同时提供时，导出前即会执行预检（不匹配直接拦截），同时省略时仅按 `unityUUID` 校验 |
| `unityTextSHA256` | 否（需与 `unityTextSize` 成对） | `UnityFramework` `__TEXT.__text` 节 64 位小写 SHA-256；必须与 `unityTextSize` 成对提供或同时省略 |
| `il2cppOffsets` | **是** | 包含下方全部 14 项相对 `UnityFramework` 镜像基址的 RVA 偏移 |
| `notes` | 否 | 可选备注 |

---

## 四、14 项 `il2cppOffsets` 偏移定义

所有偏移均为相对于 `UnityFramework` 镜像加载基址（`__TEXT.vmaddr`）的 RVA。

### A. 6 项全局槽位 / 指针校验

| 键名 | 必需 | 含义 | 2.7.91/76 真值 |
| --- | --- | --- | --- |
| `sdkInterfaceClassSlot` | **是** | `U8.SDK.U8SDKInterface` 的全局 `Il2CppClass*`（`TypeInfo`）槽位 | `0xb9a5e38` |
| `sdkExternalToolsClassSlot` | **是** | `U8.SDK.SDKExternalTools` 的全局 `Il2CppClass*`（`TypeInfo`）槽位 | `0xb99d618` |
| `sdkMetaClassSlot` | **是** | `U8.SDK.SDKMeta` 的全局 `Il2CppClass*`（`TypeInfo`）槽位 | `0xb99d6c0` |
| `networkerTypeSlot` | **是** | `Singleton<Torappu.Network.Networker>.get_instance()` 的全局 `MethodInfo*` 槽位（`MethodRef`） | `0xba1cc48` |
| `networkerExpectedClass` | 可选（可填 `0`） | 上述 `MethodInfo->methodPointer` 的期望 RVA（填 `0` 时跳过次级指针核对） | `0x6049b80` |
| `gameFlowClassSlot` | **是** | `Torappu.GameFlowController` 的全局 `Il2CppClass*`（`TypeInfo`）槽位 | `0xb98f408` |

### B. 8 项托管方法入口 RVA

| 键名 | 必需 | 对应 C# 方法签名 | 2.7.91/76 真值 |
| --- | --- | --- | --- |
| `getNetworkConfigFn` | **是** | `Torappu.Network.Networker.get_networkConfig()` | `0x77ad3ac` |
| `overrideNetworkOptionsFn` | **是** | `Torappu.Network.Networker.OverrideNetworkOptions(...)` | `0x77ad968` |
| `createStringFn` | **是** | `System.String.CreateStringForSByteConstructor(sbyte*, int)` | `0x7dcaf48` |
| `internalSDKMetaFn` | **是** | `U8.SDK.U8SDKInterface._InternalSDKMeta()` | `0x6c5aff4` |
| `sdkMetaCtorFn` | **是** | `U8.SDK.SDKMeta..ctor(string)`（单参数重载） | `0x6c62a84` |
| `clearAuthStatusFn` | **是** | `U8.SDK.U8SDKInterface.ClearAuthStatus()` | `0x6c5c478` |
| `clearLoginStatusFn` | **是** | `U8.SDK.U8SDKInterface.ClearLoginStatus()` | `0x6c5c53c` |
| `getCurrentSceneFn` | **是** | `Torappu.GameFlowController.get_currentScene()` | `0x18178d4` |

---

## 五、运行时 ABI 约束

以下内存布局由 `Bridge/Sources/ABRuntime.m` 中的 `_Static_assert` 约束，同时会被 `IL2CPPAutoResolver` 自动核验；若未来游戏大版本改动了以下任一结构体，必须同步更新桥接库而非仅替换偏移配置：

1. `U8.SDK.SDKMeta`：包含 6 个连续实例字段（全部为 `System.String`），按顺序为 `appID`、`appKey`、`channel`、`worldId`、`extension`、`appCode`（偏移自 `+0x10` 起）。
2. `NetworkConfig`（`get_networkConfig` 返回值结构体）：值类型，共 **104 字节**（12 个 `System.String` 指针 + 1 个 `bool` 开发服标记位于 `+0x60`）。
3. `NetworkOverride`（`OverrideNetworkOptions` 覆盖参数）：共 **112 字节**（`enabled` 标志 + 7 字节对齐 + 嵌套 `NetworkConfig` 位于 `+0x08`）。
4. Unity IL2CPP 对象与类头偏移：`Il2CppString.length` (`+0x10`)、`chars` (`+0x14`)；`Il2CppClass.static_fields` (`+0xb8`)、`rgctx_data` (`+0xc0`)、`initialized_and_no_error` (`+0x136`)；`MethodInfo.methodPointer` (`+0x00`)、`klass` (`+0x20`)。
