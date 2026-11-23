import IPAPatcherCore
import SwiftUI

struct HeroActionCard: View {
    let builtInKit: VerifiedPatchKit?
    let builtInKitError: String?
    let isCheckingKit: Bool
    let onSelectIPA: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 54, height: 54)
                    Image(systemName: "wand.and.rays")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("明日方舟 B 服补丁")
                        .font(.title3.weight(.semibold))
                    Text("本机离线修补 · 原 IPA 始终保持只读")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            // Compact inline readiness pill (non-cluttered)
            HStack(spacing: 8) {
                if isCheckingKit {
                    ProgressView()
                        .controlSize(.mini)
                    Text("正在校验内置底座…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } else if let kit = builtInKit {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text("底座已就绪 · 内置 \(kit.manifest.version) 基准（\(kit.payloadEntryCount) 项已核验）")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                } else if let err = builtInKitError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("底座异常：\(err)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
            )

            // Primary CTA
            Button(action: onSelectIPA) {
                Label("选择已解密 IPA", systemImage: "doc.badge.plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(builtInKitError != nil)

            // Compact 3-step horizontal flow indicator
            HStack(spacing: 6) {
                stepChip(number: "1", title: "选包识别")
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.quaternary)
                stepChip(number: "2", title: "预检打包")
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.quaternary)
                stepChip(number: "3", title: "复核导出")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func stepChip(number: String, title: String) -> some View {
        HStack(spacing: 5) {
            Text(number)
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.accentColor.opacity(0.14)))
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
