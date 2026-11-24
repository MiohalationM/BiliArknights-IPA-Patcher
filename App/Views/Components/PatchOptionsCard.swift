import IPAPatcherCore
import SwiftUI

struct PatchOptionsCard: View {
    @Binding var applyCustomBiliIcons: Bool
    @Binding var enableAutoAdaptation: Bool
    let customProfileCount: Int
    let builtInVersionLabel: String
    let onManageProfiles: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("打包设置")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)

            // Row 1: Visual App Icon Selector
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    IconBadge(systemName: "app.badge", color: AppTheme.brandCyan, size: 30)
                    Text("桌面图标")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }

                HStack(spacing: 10) {
                    iconChoiceTile(
                        title: "B 服图标",
                        subtitle: "默认推荐",
                        showBiliBadge: true,
                        isSelected: applyCustomBiliIcons
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            applyCustomBiliIcons = true
                        }
                    }

                    iconChoiceTile(
                        title: "保留原版",
                        subtitle: "维持原图标",
                        showBiliBadge: false,
                        isSelected: !applyCustomBiliIcons
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            applyCustomBiliIcons = false
                        }
                    }
                }

                Text(applyCustomBiliIcons
                     ? "桌面显示带「B」角标的新图标，方便和官服区分"
                     : "保留游戏原本的桌面图标，不做额外修改")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)

            Divider()
                .padding(.leading, 58)

            // Row 2: Auto-adaptation switch
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $enableAutoAdaptation) {
                    HStack(spacing: 10) {
                        IconBadge(systemName: "sparkles", color: .indigo, size: 30)
                        Text("游戏更新后自动适配")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .tint(AppTheme.brandCyan)

                Text("当游戏更新到新版本时自动分析并适配，建议保持开启")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 40)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()
                .padding(.leading, 58)

            // Row 3: Manual profile management & developer tools
            Button(action: onManageProfiles) {
                HStack(spacing: 10) {
                    IconBadge(systemName: "slider.horizontal.3", color: .teal, size: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("版本配置与高级工具")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(profileSummaryText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .appCard(cornerRadius: 20)
    }

    private func iconChoiceTile(
        title: String,
        subtitle: String,
        showBiliBadge: Bool,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                miniIconPreview(showBiliBadge: showBiliBadge)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Spacer(minLength: 2)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isSelected ? AppTheme.brandCyan : Color(.tertiaryLabel))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        isSelected
                            ? AppTheme.brandCyan.opacity(colorScheme == .dark ? 0.16 : 0.09)
                            : Color(.tertiarySystemFill).opacity(0.65)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(
                                isSelected ? AppTheme.brandCyan.opacity(0.65) : Color.clear,
                                lineWidth: 1.4
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func miniIconPreview(showBiliBadge: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [AppTheme.brandNavyStart, AppTheme.brandNavyEnd],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                )

            if showBiliBadge {
                Text("B")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .fill(AppTheme.brandCyan)
                    )
                    .offset(x: 3, y: 3)
            }
        }
        .padding(.trailing, showBiliBadge ? 2 : 0)
    }

    private var profileSummaryText: String {
        if customProfileCount > 0 {
            return "内置 \(builtInVersionLabel) · 已导入 \(customProfileCount) 份新版本配置"
        }
        return "内置 \(builtInVersionLabel) · 支持导入新版配置"
    }
}
