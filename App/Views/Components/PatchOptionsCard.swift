import IPAPatcherCore
import SwiftUI

struct PatchOptionsCard: View {
    @Binding var applyCustomBiliIcons: Bool
    @Binding var enableAutoAdaptation: Bool
    let customProfileCount: Int
    let builtInVersionLabel: String
    let onManageProfiles: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("修补选项")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)

            // Row 1: App Icon selector
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("应用图标", systemImage: "app.dashed")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
                Picker("应用图标", selection: $applyCustomBiliIcons) {
                    Text("B 服图标").tag(true)
                    Text("保留原版").tag(false)
                }
                .pickerStyle(.segmented)

                Text(applyCustomBiliIcons
                     ? "替换为 B 服角标桌面图标（推荐，方便区分官服与 B 服）"
                     : "保留原版官服图标，不修改 Info.plist 图标配置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)

            Divider()
                .padding(.leading, 18)

            // Row 2: Auto-adaptation switch
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $enableAutoAdaptation) {
                    Label("自动适配未知新版本", systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.medium))
                }
                .tint(.accentColor)

                Text("当游戏更新超出内置版本且无手工配置时，自动从单份 IPA 解析 IL2CPP 偏移并校验结构体布局")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()
                .padding(.leading, 18)

            // Row 3: Manual profile management & built-in kit inspection
            Button(action: onManageProfiles) {
                HStack(spacing: 12) {
                    Label("适配配置管理", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 8)

                    Text(profileSummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var profileSummaryText: String {
        if customProfileCount > 0 {
            return "内置 \(builtInVersionLabel) · 手工 \(customProfileCount) 份"
        }
        return "内置 \(builtInVersionLabel) · 可导入手工版"
    }
}
