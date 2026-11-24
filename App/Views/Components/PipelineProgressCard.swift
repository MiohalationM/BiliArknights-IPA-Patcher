import IPAPatcherCore
import SwiftUI

struct PipelineProgressCard: View {
    let fileName: String
    let fileSize: UInt64?
    let progress: PatchProgress
    let onCancel: () -> Void

    private var clampedFraction: Double {
        min(max(progress.fractionCompleted ?? 0, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Top active stage header
            HStack(alignment: .center, spacing: 12) {
                IconBadge(systemName: "arrow.triangle.2.circlepath", color: AppTheme.brandCyan, size: 42, iconScale: 0.48)

                VStack(alignment: .leading, spacing: 3) {
                    Text(progress.stage.title)
                        .font(.headline)
                    HStack(spacing: 5) {
                        Text(fileName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let fileSize {
                            Text("· \(formattedBytes(fileSize))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                if progress.fractionCompleted != nil {
                    Text("\(Int((clampedFraction * 100).rounded()))%")
                        .font(.system(.title3, design: .rounded).monospacedDigit().weight(.bold))
                        .foregroundStyle(AppTheme.brandCyan)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            // Sleek custom gradient progress bar
            VStack(alignment: .leading, spacing: 8) {
                if progress.fractionCompleted != nil {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color(.tertiarySystemFill))
                            Capsule()
                                .fill(AppTheme.progressGradient)
                                .frame(width: max(8, geo.size.width * clampedFraction))
                                .animation(.easeOut(duration: 0.18), value: clampedFraction)
                        }
                    }
                    .frame(height: 8)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(AppTheme.brandCyan)
                }

                Text(progress.detailMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let processed = progress.processedBytes, let total = progress.totalBytes, total > 0 {
                    HStack {
                        Text("已处理 \(formattedBytes(processed)) / \(formattedBytes(total))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Spacer()
                        if let done = progress.completedEntries, let all = progress.totalEntries {
                            Text("\(done) / \(all) 个文件")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Divider()

            // Connected vertical stage checklist
            VStack(alignment: .leading, spacing: 0) {
                let stages = PatchPipelineStage.allCases
                ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                    stageRow(stage, isLast: index == stages.count - 1)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("处理期间请尽量保持屏幕常亮，通常只需十几秒。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Button(role: .destructive, action: onCancel) {
                Label("取消处理", systemImage: "xmark.circle")
            }
            .buttonStyle(AppSecondaryButtonStyle(tint: .red))
        }
        .padding(20)
        .appCard(cornerRadius: 22)
    }

    private func stageRow(_ stage: PatchPipelineStage, isLast: Bool) -> some View {
        let isCompleted = stage.rawValue < progress.stage.rawValue
        let isActive = stage == progress.stage

        return HStack(alignment: .top, spacing: 11) {
            VStack(spacing: 0) {
                Group {
                    if isCompleted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if isActive {
                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            .foregroundStyle(AppTheme.brandCyan)
                    } else {
                        Image(systemName: "circle")
                            .foregroundStyle(.quaternary)
                    }
                }
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 20, height: 20)

                if !isLast {
                    Rectangle()
                        .fill(isCompleted ? Color.green.opacity(0.45) : Color(.separator).opacity(0.45))
                        .frame(width: 1.5, height: 14)
                        .padding(.vertical, 2)
                }
            }

            Text(stage.title)
                .font(.subheadline.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .primary : (isCompleted ? .secondary : .tertiary))
                .padding(.top, 1)

            Spacer()

            if isActive {
                Text("进行中")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.brandCyan)
                    .padding(.top, 3)
            }
        }
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }
}
