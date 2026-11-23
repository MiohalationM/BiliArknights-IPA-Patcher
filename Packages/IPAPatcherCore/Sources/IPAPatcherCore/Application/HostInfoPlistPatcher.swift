import Foundation

/// Dynamically merges the minimal B-server SDK delta into the host IPA's own `Info.plist`,
/// preserving the host game's version, build, scene manifest, plugins, and system keys across updates.
public enum HostInfoPlistPatcher {
    public static let biliURLScheme = "bili2c270e4f601f424f"
    public static let requiredQuerySchemes = ["bilibili", "bilibili.following"]
    public static let defaultTrackingUsage = "B站游戏SDK请求使用设备广告标识符进行广告归因与效果统计。你可以选择不允许跟踪。"

    public static func patch(
        hostInfoPlistData: Data,
        revision: String,
        expectedBundleID: String,
        applyCustomBiliIcons: Bool = true
    ) throws -> Data {
        let obj: Any
        do {
            obj = try PropertyListSerialization.propertyList(from: hostInfoPlistData, options: [], format: nil)
        } catch {
            throw PatchError.invalidInfoPlist("解析宿主 Info.plist 失败：\(error.localizedDescription)")
        }
        guard var dict = obj as? [String: Any] else {
            throw PatchError.invalidInfoPlist("宿主 Info.plist 顶层不是字典")
        }
        guard (dict["CFBundleIdentifier"] as? String) == expectedBundleID else {
            throw PatchError.invalidPatchedMetadata("宿主 Info.plist 包名与配置不符")
        }

        // 1. Mark packaging revision & display name.
        dict["ABPackagingRevision"] = revision
        dict["CFBundleName"] = "明日方舟"

        // 2. Ensure ATT usage description exists for Bilibili SDK's tracking request.
        if (dict["NSUserTrackingUsageDescription"] as? String)?.isEmpty ?? true {
            dict["NSUserTrackingUsageDescription"] = defaultTrackingUsage
        }

        // 3. Apply B-server icon references (if ABAppIcon* assets are included in kit).
        if applyCustomBiliIcons {
            dict["CFBundleIcons"] = [
                "CFBundlePrimaryIcon": [
                    "CFBundleIconFiles": [
                        "ABAppIcon60x60",
                        "ABAppIcon40x40",
                        "ABAppIcon29x29"
                    ]
                ]
            ]
            dict["CFBundleIcons~ipad"] = [
                "CFBundlePrimaryIcon": [
                    "CFBundleIconFiles": [
                        "ABAppIcon60x60",
                        "ABAppIcon76x76",
                        "ABAppIcon83.5x83.5",
                        "ABAppIcon40x40",
                        "ABAppIcon29x29"
                    ]
                ]
            ]
        }

        // 4. Patch only the 3 B-server channel fields inside `U8SDK`, preserving all Plugins & host keys.
        var u8sdk = (dict["U8SDK"] as? [String: Any]) ?? [:]
        u8sdk["AppId"] = 1
        u8sdk["AppKey"] = "ea3e65c0259e6ae1a6eabca899fcb6b0"
        u8sdk["Channel"] = 2
        u8sdk["World"] = 2
        dict["U8SDK"] = u8sdk

        // 5. Ensure Bilibili OAuth URL scheme is registered in CFBundleURLTypes.
        var urlTypes = (dict["CFBundleURLTypes"] as? [[String: Any]]) ?? []
        let hasBiliScheme = urlTypes.contains { item in
            let schemes = item["CFBundleURLSchemes"] as? [String] ?? []
            return schemes.contains(biliURLScheme)
        }
        if !hasBiliScheme {
            urlTypes.append([
                "CFBundleTypeRole": "Editor",
                "CFBundleURLSchemes": [biliURLScheme]
            ])
            dict["CFBundleURLTypes"] = urlTypes
        }

        // 6. Ensure Bilibili app query schemes are present in LSApplicationQueriesSchemes.
        var querySchemes = (dict["LSApplicationQueriesSchemes"] as? [String]) ?? []
        for scheme in requiredQuerySchemes where !querySchemes.contains(scheme) {
            querySchemes.append(scheme)
        }
        dict["LSApplicationQueriesSchemes"] = querySchemes

        do {
            return try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        } catch {
            throw PatchError.invalidPatchedMetadata("序列化补丁后 Info.plist 失败：\(error.localizedDescription)")
        }
    }
}
