import IPAPatcherCore
import SwiftUI

struct HeroActionCard: View {
    let builtInKit: VerifiedPatchKit?
    let builtInKitError: String?
    let isCheckingKit: Bool
    let onSelectIPA: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Brand header
            HStack(alignment: .center, spacing: 14) {
                RhodesEmblemIcon(size: 54)

                VStack(alignment: .leading, spacing: 4) {
                    Text("明日方舟 B 服补丁")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                    Text("全程本地离线处理 · 不会改动原游戏包")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            // Readiness status pill
            HStack(spacing: 8) {
                if isCheckingKit {
                    ProgressView()
                        .controlSize(.mini)
                    Text("正在准备内置补丁组件…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } else if let kit = builtInKit {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                    Text("补丁就绪 · 内置 \(kit.manifest.version)，新版通过兼容校验后可自动适配")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                } else if let err = builtInKitError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("补丁组件异常：\(err)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        colorScheme == .dark
                            ? Color.white.opacity(0.06)
                            : AppTheme.brandCyan.opacity(0.07)
                    )
            )

            // Primary CTA
            Button(action: onSelectIPA) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.badge.plus")
                        .font(.body.weight(.semibold))
                    Text("选择砸壳 IPA")
                }
            }
            .buttonStyle(AppPrimaryButtonStyle())
            .disabled(builtInKitError != nil)

            // 3-step beginner journey indicator
            HStack(spacing: 4) {
                stepChip(number: "1", title: "选砸壳包")
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.quaternary)
                stepChip(number: "2", title: "打 B 服补丁")
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.quaternary)
                stepChip(number: "3", title: "导出安装")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
        }
        .padding(20)
        .appCard(cornerRadius: 22)
    }

    private func stepChip(number: String, title: String) -> some View {
        HStack(spacing: 5) {
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.brandCyan)
                .frame(width: 18, height: 18)
                .background(Circle().fill(AppTheme.brandCyan.opacity(0.14)))
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
    }
}
