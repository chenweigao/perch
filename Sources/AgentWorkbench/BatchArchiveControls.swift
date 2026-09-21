import SwiftUI
import WorkbenchCore

/// One batch entry point: the count, what it will leave behind, and the outcome of
/// the last run with undo. Deliberately not a per-item confirmation dialog.
struct BatchArchiveControls: View {
    var showsArchiveAction = true
    let count: Int
    let blockedSummary: String?
    let isRunning: Bool
    let result: BatchArchiveRun?
    let onArchive: () -> Void
    let onUndo: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsArchiveAction {
                HStack(spacing: 10) {
                    Button(action: onArchive) {
                        Label(isRunning ? "正在归档…" : "归档已完成 \(count)", systemImage: "archivebox")
                    }
                    .disabled(count == 0 || isRunning)
                    .help(count == 0 ? "当前范围内没有可归档的已完成会话" : "批量归档当前范围内本轮已正常结束且结果已查看的会话")
                    .accessibilityLabel("归档已完成的 \(count) 个会话")
                    if isRunning { ProgressView().controlSize(.small) }
                }
                // Explain why other sessions are left out of the batch.
                if let blockedSummary {
                    Text(blockedSummary).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let result, result.isFinished {
                HStack(spacing: 10) {
                    Text(result.summary).font(.caption)
                    if !result.archived.isEmpty {
                        Button(result.undoFailures.isEmpty ? "撤销" : "重试恢复失败项") { onUndo() }.font(.caption).disabled(isRunning)
                            .help("仅恢复本次实际归档成功的 \(result.archived.count) 个会话")
                    }
                    if result.retryPlan != nil {
                        Button("只重试失败项") { onRetry() }.font(.caption).disabled(isRunning)
                    }
                }
                if !result.skipped.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(result.skipped.prefix(4), id: \.candidate.id) { item in
                            Text("跳过：\(item.skip.reason)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if !result.failures.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(result.failures.prefix(4), id: \.candidate.id) { item in
                            Text("失败：\(item.message)").font(.caption2).foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                    }
                }
                ForEach(result.undoFailures, id: \.candidate.id) { item in
                    Text("恢复失败：\(item.message)").font(.caption2).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
        }
    }
}
