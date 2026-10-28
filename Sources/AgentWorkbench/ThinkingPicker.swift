import SwiftUI
import WorkbenchCore

struct ThinkingPicker: View {
    @UILocalization private var L
    let model: AgentModel?
    let current: ThinkingLevel?
    let disabled: Bool
    var unavailableReason: String?
    let onSelect: (ThinkingLevel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("思考强度").font(.system(size: WorkbenchTheme.Typography.body, weight: .medium))
                .padding(.horizontal, 10)
            if let unavailableReason {
                explanation(unavailableReason)
            } else if let model, model.supportsThinking {
                VStack(spacing: 2) {
                    ForEach(model.thinking, id: \.self) { level in
                        ModelPickerRow(title: Text(verbatim: level.label), detail: nil,
                                       selected: level == model.resolve(current)) { onSelect(level) }
                            .disabled(disabled)
                            .accessibilityLabel(L("思考：\(level.label)"))
                            .accessibilityIdentifier("thinking-level:\(level.rawValue)")
                    }
                }
                Text("较高强度会花更多时间思考。")
                    .font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model?.hasThinkingCapability == true {
                explanation(L("支持思考，但尚未声明可选档位。请补充 Agent 的模型配置。"))
            } else {
                explanation(model == nil ? L("尚未读取到当前模型的思考档位。") : L("此模型未提供思考档位设置。"))
            }
        }
    }

    private func explanation(_ text: String) -> some View {
        Text(text).font(.system(size: WorkbenchTheme.Typography.body)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A quiet indicator of the latest reported context, with details on demand.
struct ContextMeter: View {
    @UILocalization private var L
    let budget: ContextBudget?
    var reportedAt: Double? = nil
    var isStale = false
    /// Present on Kimi sessions: the auto-compact toggle writes per-session settings.
    var autoCompactHost: UUID? = nil
    var autoCompactSession: String? = nil
    @State private var presented = false
    @ObservedObject private var autoCompactStore = AutoCompactStore.shared

    private var summary: String {
        if isStale { return L("上下文用量未同步") }
        guard let budget else { return L("上下文用量未知") }
        let percent = "\(budget.remainingPercent)%"
        return L("上下文剩余约 \(percent)")
    }
    private var tint: Color {
        guard !isStale, let budget else { return .secondary }
        switch budget.pressure {
        case .comfortable: return .secondary
        case .tight: return .orange
        case .critical: return .red
        }
    }
    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 5) {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 2)
                    if let budget, !isStale {
                        Circle().trim(from: 0, to: budget.usedFraction)
                            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    } else {
                        Text(isStale ? "–" : "?").font(.system(size: 9, weight: .medium))
                    }
                }.frame(width: 14, height: 14)
                if isStale {
                    Text(L("未同步")).font(.system(size: WorkbenchTheme.Typography.caption))
                } else if let budget, budget.pressure != .comfortable {
                    Text(L("上下文将满")).font(.system(size: WorkbenchTheme.Typography.caption))
                }
            }.foregroundStyle(tint).frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).fixedSize()
            .help(summary).accessibilityLabel(summary)
            .popover(isPresented: $presented) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(summary).font(.system(size: WorkbenchTheme.Typography.title, weight: .semibold))
                    if let budget {
                        Text(L("已用 \(ContextBudget.short(budget.used)) / \(ContextBudget.short(budget.limit)) tokens"))
                            .monospacedDigit()
                        Text(L("最近一次 Agent 上报的用量，不含未发送草稿；运行中可能继续增长。"))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L("Agent 尚未提供可用的上下文用量。"))
                            .foregroundStyle(.secondary)
                    }
                    if let reportedAt {
                        HStack(spacing: 4) {
                            Text(L("上报时间"))
                            Text(Date(timeIntervalSince1970: reportedAt), style: .date)
                            Text(Date(timeIntervalSince1970: reportedAt), style: .time)
                        }.font(.system(size: WorkbenchTheme.Typography.secondary)).foregroundStyle(.secondary)
                    } else {
                        Text(L("上报时间未提供")).font(.system(size: WorkbenchTheme.Typography.secondary)).foregroundStyle(.secondary)
                    }
                    if let autoCompactHost, let autoCompactSession {
                        Divider()
                        let settings = autoCompactStore.settings(host: autoCompactHost, session: autoCompactSession)
                        Toggle(L("上下文将满时自动压缩"), isOn: Binding(
                            get: { settings.enabled },
                            set: { value in
                                var next = settings; next.enabled = value
                                autoCompactStore.set(host: autoCompactHost, session: autoCompactSession, next)
                            }))
                        if settings.enabled {
                            Stepper(value: Binding(
                                get: { settings.threshold },
                                set: { value in
                                    var next = settings; next.threshold = value
                                    autoCompactStore.set(host: autoCompactHost, session: autoCompactSession, next)
                                }), in: 50...95, step: 5) {
                                Text(L("阈值 \(settings.threshold)%"))
                            }
                            Text(L("任务空闲且用量达到阈值时自动压缩，完成后继续任务。"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }.font(.system(size: WorkbenchTheme.Typography.body)).padding(16).frame(width: 290, alignment: .leading)
            }
    }
}
