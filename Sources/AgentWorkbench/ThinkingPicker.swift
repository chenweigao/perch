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
            HStack {
                Text("思考强度").font(.system(size: 12, weight: .medium))
                Spacer()
                if let model, model.supportsThinking, unavailableReason == nil {
                    Text(model.resolve(current).map { L(key: $0.label) } ?? L("默认"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if let unavailableReason {
                explanation(unavailableReason)
            } else if let model, model.supportsThinking {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], spacing: 6) {
                    ForEach(model.thinking, id: \.self) { level in
                        let selected = level == model.resolve(current)
                        Button { onSelect(level) } label: {
                            Text(L(key: level.label)).font(.system(size: 12, weight: selected ? .semibold : .regular))
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                                .background(Color.primary.opacity(selected ? 0.09 : 0.025), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(selected ? 0.3 : 0.08), lineWidth: 1))
                                .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain).disabled(disabled)
                        .accessibilityLabel(L("思考：\(L(key: level.label))"))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("thinking-level:\(level.rawValue)")
                    }
                }
            } else {
                explanation(model == nil ? L("尚未读取到当前模型的思考档位。") : L("此模型未提供思考档位设置。"))
            }
        }
    }

    private func explanation(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Remaining context for the current session. Absent until the runtime reports a
/// window, since zero of zero would read as an empty context rather than unknown.
struct ContextMeter: View {
    let budget: ContextBudget?

    var body: some View {
        if let budget {
            Text("\(budget.remainingPercent)% left").font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(budget.pressure == .comfortable ? .secondary : tint(budget.pressure))
                .help(budget.summary + "\n" + budget.detail)
                .accessibilityLabel(budget.summary).fixedSize()
        } else {
            Text("Context unknown").font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize().help("Context usage is not available yet. It usually appears after the first turn.")
        }
    }

    private func tint(_ pressure: ContextBudget.Pressure) -> Color {
        switch pressure {
        case .comfortable: return .secondary
        case .tight: return .orange
        case .critical: return .red
        }
    }
}
