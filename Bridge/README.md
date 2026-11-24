# 桥接源码与内置底座构建说明（`Bridge/`）

本目录维护 **数据驱动的开源桥接层 `ABLoginBridge.dylib`**，配合 **完整官方 B 站 SDK 载体 `ABSDKCarrier.dylib`**，通过 `build_kit.py` 打包为 `IPAPatcherCore` 内置底座（`Resources/Kits/carrier-2.7.91/`）。

---

## 为什么采用「源码桥接 + 官方 SDK 载体」

- **桥接层（约 70 KB 源码 → 编译产物约 149 KB）**：负责拦截游戏登录入口、切换游戏服路由（`ak-gs-gf` ↔ `ak-gs-b`）、改写 `U8.SDK.SDKMeta` 与托管/原生渠道参数、管理悬浮窗与回调转发。这部分逻辑完全透明、已逐行审计并重构为数据驱动。
- **官方 B 站 SDK（`ABSDKCarrier.dylib`，约 9.2 MB）**：包含 B 站 v4 完整登录界面、风控/极验验证码（`GSRiskControlModuel` / `GSGeetestView`）、弹窗管理（`GSPopupVCManager`）与协议服务（`GSCAgreementService`）。直接使用上游提取的完整官方 SDK，仅剥离原捆绑桥接符号，既稳定又无需反向维护闭源 SDK。

---

## 源码清单（`Bridge/Sources/`）

| 文件 | 职责 |
| --- | --- |
| `ABBridge.h` | 桥接内部头文件，定义 `ABRuntimeOffsetProfile`（14 项偏移 + UUID/代码段指纹）与公共函数声明 |
| `ABPolicy.h` / `ABPolicy.c` | 纯 C 渠道/场景状态机与合法域名白名单校验 |
| `ABLoginResult.h` / `ABLoginResult.m` | B 站 SDK 登录结果向 U8SDK 格式转换 |
| `ABRecoveredInterfaces.h` | 与 `GSSDK` / `U8SDK` 运行时交互的 Objective-C 协议声明（零链接期依赖） |
| `ABChannelControl.m` | 渠道状态持久化与切换控制 |
| `ABLoginCallbacks.m` | B 服/官服登录回调去重、超时保护与转发 |
| `ABRuntime.m` | 数据驱动 IL2CPP 运行时路由：启动时读取主包 `ABRuntimeProfile.plist`（缺省回退至 2.7.91/76 验证值），提供 `ABIL2CPPExportDiagnostic()` 诊断 |
| `ABHooks.m` | 动态 Objective-C 方法签名与 selector 检查（**无硬编码 ObjC IMP 偏移**），核验 `UnityFramework` UUID 与可选 `__text` 哈希后安装 6 个 Hook |
| `ABBootstrap.m` | 延迟到主队列通过 `dlopen(RTLD_NOW \| RTLD_LOCAL)` 优先加载同目录 `ABSDKCarrier.dylib`，维护右上角安全区悬浮切换按钮与自定义暗色下拉面板，并在窗口层级变化时自动重挂载 |

---

## 构建与更新底座

```sh
# 运行桥接核心单元测试（ABPolicy + ABLoginResult）
./Bridge/tests/run_tests.sh

# 构建并打包确定性底座（可通过 --upstream-kit 指定上游 kit 目录）
python3 Bridge/build_kit.py [--upstream-kit <path>]
```

脚本执行以下 4 步：
1. 调用 `xcrun --sdk iphoneos clang` 以 `arm64`（`-target arm64-apple-ios13.0`）编译 `Bridge/Sources/`，输出 `Bridge/build/ABLoginBridge.dylib`。
2. 从本地参考载体生成 `Bridge/build/ABSDKCarrier.dylib`（将原入口构造函数 `0xeb90` 置为 `ret`，并将冲突类名 `ABLoginCoordinator`/`ABBootstrap` 重命名为 `ZB*`）。
3. 生成默认基准 `ABRuntimeProfile.plist`，连同桥接库、官方 SDK 载体、B 站 SDK 资源与 B 服图标一起打包为 `payload.zip` 与 `manifest.json`，写入：
   `Packages/IPAPatcherCore/Sources/IPAPatcherCore/Resources/Kits/carrier-2.7.91/`。
4. 打印新的 `manifest.json` 与 `payload.zip` SHA-256。

> **注意**：若修改了 `Bridge/Sources/` 并重新运行了 `build_kit.py`，请同步更新 [PatchKitModels.swift](../Packages/IPAPatcherCore/Sources/IPAPatcherCore/Models/PatchKitModels.swift) 中的 `BuiltInKitRepository.lockedManifestSHA256`，然后运行 `swift test` 与 `swift run ipa-patcher-cli verify-kit` 确认全部通过。
