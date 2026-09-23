import SwiftUI
import WorkbenchCore

/// Reasoning effort for the selected model. Native runtimes do not reject every
/// unrecognised level consistently, so only levels declared by the selected model
/// are offered, and a model without a declared set explains why this is unavailable.
struct ThinkingPicker: View {
    let model: AgentModel?
    let current: ThinkingLevel?
    let disabled: Bool
    let onSelect: (ThinkingLevel) -> Void

    var body: some View {
        if let model, model.supportsThinking {
            Menu {
                ForEach(model.thinking, id: \.self) { level in
                    Button {
                        onSelect(level)
                    } label: {
                        if level == (current ?? model.defaultThinking) { Label(level.label, systemImage: "checkmark") } else { Text(level.label) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Thinking: \(current?.label ?? model.defaultThinking?.label ?? "Default")")
                        .font(.system(size: 12))
                }.foregroundStyle(.secondary)
            }.menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
                .disabled(disabled)
                .help("Thinking effort for the next turn. Available levels depend on the model.")
                .accessibilityLabel("Choose thinking effort")
        }
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
