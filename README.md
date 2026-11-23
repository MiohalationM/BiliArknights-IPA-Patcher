<div align="center">

# 方舟补丁工具 · ArknightsPatcher

**纯手机端离线修补 · 数据驱动源码桥接 · 单 IPA IL2CPP 自动定位**

[![Platform](https://img.shields.io/badge/Platform-iOS%2027.0%2B%20%7C%20macOS%2015%2B-0A84FF?style=flat-square)](https://github.com/MiohalationM/ArknightsPatcher)
[![Swift](https://img.shields.io/badge/Swift-6.0-F05138?style=flat-square)](https://swift.org)
[![Release](https://img.shields.io/github/v/release/MiohalationM/ArknightsPatcher?style=flat-square&label=Release&color=34C759)](https://github.com/MiohalationM/ArknightsPatcher/releases/latest)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)

[项目主页 (GitHub Pages)](https://miohalationm.github.io/ArknightsPatcher/) · [下载最新工具 IPA](https://github.com/MiohalationM/ArknightsPatcher/releases/latest) · [手工配置规范](docs/PROFILE_FORMAT.md) · [桥接源码说明](Bridge/README.md)

</div>

---

## 项目简介

**ArknightsPatcher（方舟补丁工具）** 是一款原生 iPhone 应用（Swift 6 / SwiftUI）与跨平台核心库（`IPAPatcherCore` + `Zip64Kit`），用于在 **iPhone 本机完全离线** 将已解密的官服 iOS《明日方舟》IPA 修补为可切换 Bilibili 服登录的待签名 IPA：

- **不解密、不签名、不联网、不修改原始 IPA**。
- 面向大体积游戏包（约 2.8 GB）设计，采用单遍流式 ZIP64（未改条目 2 MB 分块零重压直通），处理后强制 100% 校验 ZIP CRC32 与补丁条目 SHA-256。

> **致谢与参考项目**  
> 本项目的 B 服渠道路由、SDK 桥接协议与早期基线分析深度参考了开源项目：[lazhire/Arknights-Bilibili-for-IOS](https://github.com/lazhire/Arknights-Bilibili-for-IOS)，在此致以诚挚感谢。

---

## 核心特性

### 1. 三层适配机制（游戏更新无需重装 App）
1. **手工导入配置（最高优先级）**：支持在 App 内「适配配置管理」或从「文件」直接打开 `.json` / `ABRuntimeProfile.plist` 导入，按 `bundleID + version + build + UnityFramework UUID` 精确匹配。格式规范见 [docs/PROFILE_FORMAT.md](docs/PROFILE_FORMAT.md)。
2. **内置已验证基准**：内置明日方舟 `2.7.91`（build `76`）全量 6 个宿主二进制 UUID 严格校验，与源码桥接 `ABLoginBridge.dylib` 配合完成真机 B 服切换与登录验证。
3. **本机单 IPA 自动定位（IL2CPP）**：首页一键开关「自动适配未知新版本」。直接解析单份 IPA 内的明文 `global-metadata.dat`（支持 IL2CPP `v27` / `v29` / `v31`）与 `UnityFramework` Mach-O（支持 `LC_DYLD_CHAINED_FIXUPS` 与 ARM64 `ADRP + LDR/ADD` 双重印证），自动定位 14 项运行时偏移并执行字节级结构体 ABI 校验（`SDKMeta`、`NetworkConfig`、`NetworkOverride`）；证据不足或结构体布局变化时安全中止，禁止盲目导出。

### 2. 自定义选项与安全存储
- **应用图标选项**：支持在「B 服图标」与「保留原版」间自由切换（选择保留原版时跳过 `CFBundleIcons` 改写及 `ABAppIcon*.png` 写入）。
- **动态 Mach-O 注入**：自动解析 `UnityFramework` Load Commands 并在零字节空隙写入 `LC_LOAD_DYLIB`，拦截重复注入。
- **动态 `Info.plist` 合并**：仅增量合并 B 服渠道与 B 站 SDK 所需键，完整保留宿主版本号、构建号与插件表。
- **防误删与原子暂存**：先写 `.partial` 并全量复核后再移入 `Application Support/PendingExports/`（已排除 iCloud 备份，切出去清空间或强杀均不丢件），支持随时手动删除释放空间。

---

## 最新 Release 下载

> **关于源码仓库不含 `payload.zip` 的说明**  
> 为避免在 Git 源码历史中托管闭源第三方商业 SDK 二进制，本仓库 **仅包含纯开源代码、工程配置与文档**（`payload.zip` 与构建成品 `.ipa` 均已通过 `.gitignore` 排除）。  
> 普通用户请直接前往 [Releases](https://github.com/MiohalationM/ArknightsPatcher/releases/latest) 下载打包好的未签名工具 IPA，签名安装即可使用。

| 版本 | 产物文件名 | 大小 | SHA-256 |
| --- | --- | --- | --- |
| `v1.0.0-build13` | `ArknightsPatcher-1.0.0-build13-unsigned.ipa` | 5.5 MB | `6abb76e8901df68951ddaf4faddff999a115b736488d5b299c1f9517e899d0da` |

---

## 仓库结构

```text
ArknightsPatcher/
├── project.yml                         # XcodeGen 工程配置（Info.plist 键统一在此维护）
├── ArknightsPatcher.xcodeproj/         # Xcode 工程
├── App/                                # iOS 27.0 SwiftUI 应用源码
│   ├── Models/PatchSessionState.swift
│   ├── Services/
│   │   ├── PatchPipelineViewModel.swift
│   │   ├── CustomProfileStore.swift
│   │   └── TempWorkspaceManager.swift
│   └── Views/
├── Packages/IPAPatcherCore/            # 独立跨平台 Swift Package（macOS 15+ / iOS 27.0+，零外部依赖）
│   ├── Sources/Zip64Kit/               # 单遍流式 ZIP64 读写与 CRC32 校验
│   ├── Sources/IPAPatcherCore/         # 宿主识别、IL2CPP 解析、三层匹配、动态注入与重打包
│   ├── Sources/IPAPatcherCLI/          # macOS 命令行工具（verify-kit / inspect / self-check / match / patch）
│   └── Tests/                          # 单元测试套件（Zip64KitTests + IPAPatcherCoreTests）
├── Bridge/                             # 自维护数据驱动桥接源码（ABLoginBridge.dylib）与打包脚本
└── docs/
    ├── index.html                      # GitHub Pages 项目主页
    └── PROFILE_FORMAT.md               # 手工适配配置规范（JSON / Plist）
```

---

## 开发者构建与测试（Mac）

### 1. 运行核心包测试
> 注：由于源码仓库不含闭源 `payload.zip`，运行依赖内置底座的集成测试或编译完整 App 前，需先自行准备本地 `carrier-2.7.91/payload.zip`（详见 [Bridge/README.md](Bridge/README.md)）。

```sh
cd Packages/IPAPatcherCore
swift test
```

### 2. macOS CLI 工具
```sh
cd Packages/IPAPatcherCore

# 查看 IPA 宿主信息与 IL2CPP 探测结果
swift run ipa-patcher-cli inspect /path/to/Arknights-decrypted.ipa

# 盲测 IL2CPP 自动定位并与 2.7.91 基准逐项对照
swift run ipa-patcher-cli self-check /path/to/Arknights-2.7.91-decrypted.ipa

# 命令行修补（支持保留原版图标、指定手工配置、--force 原子替换）
swift run ipa-patcher-cli patch /path/to/Arknights.ipa /tmp/out \
  --original-icon \
  --profile /path/to/profile.json
```

### 3. 重新生成 Xcode 工程并编译 Release IPA
```sh
xcodegen generate

xcodebuild \
  -project ArknightsPatcher.xcodeproj \
  -scheme ArknightsPatcher \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/arknights-patcher-build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build
```

---

## 免责声明

- 本项目仅用于 **iOS 逆向工程、Mach-O 动态注入与 Unity IL2CPP 元数据结构研究与学习**，使用 [MIT License](LICENSE) 开源。
- 本工具 **不提供任何解密、绕过 DRM 或破解功能**，亦不在源码仓库中分发任何游戏本体或第三方闭源商业 SDK 二进制。
- 请勿将本项目用于任何商业用途或违反相关游戏服务条款的行为，使用本工具所产生的一切风险由使用者自行承担。
