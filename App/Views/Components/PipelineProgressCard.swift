import IPAPatcherCore
import SwiftUI

struct PipelineProgressCard: View {
    let fileName: String
    let fileSize: UInt64?
    let progress: PatchProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(progress.stage.title)
                        .font(.headline)
                    HStack(spacing: 6) {
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
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                if let fraction = progress.fractionCompleted {
                    ProgressView(value: min(max(fraction, 0), 1))
                        .tint(Color.accentColor)

                    HStack {
                        Text(progress.detailMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                        Text("\(Int((min(max(fraction, 0), 1) * 100).rounded()))%")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                    Text(progress.detailMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let processed = progress.processedBytes, let total = progress.totalBytes, total > 0 {
                    HStack {
                        Text("\(formattedBytes(processed)) / \(formattedBytes(total))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Spacer()
                        if let done = progress.completedEntries, let all = progress.totalEntries {
                            Text("条目 \(done)/\(all)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                ForEach(PatchPipelineStage.allCases) { stage in
                    stageRow(stage)
                }
            }

            Button(role: .destructive, action: onCancel) {
                Label("取消处理并清理临时文件", systemImage: "xmark.circle")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func stageRow(_ stage: PatchPipelineStage) -> some View {
        let isCompleted = stage.rawValue < progress.stage.rawValue
        let isActive = stage == progress.stage

        return HStack(spacing: 10) {
            Group {
                if isCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if isActive {
                    Image(systemName: "circle.dotted.circle.fill")
                        .foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.subheadline)
            .frame(width: 20)

            Text(stage.title)
                .font(.subheadline.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .primary : (isCompleted ? .secondary : .tertiary))
            Spacer()
        }
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }
}
