import SwiftUI
import WorkbenchCore

/// Reasoning effort for the selected model. Both runtimes accept an unrecognised
/// level silently, so only the levels the model itself declares are offered, and a
/// model without a declared set shows why the control is unavailable.
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
        } else if model != nil {
            Text("Thinking unavailable").font(.system(size: 11)).foregroundStyle(.tertiary)
                .help("This model does not offer adjustable thinking effort.")
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

/// Low-frequency options stay next to the context status, outside model controls.
struct ComposerOptionsButton: View {
    @Binding var manualApproval: Bool
    @State private var presented = false
    var body: some View {
        Button { presented.toggle() } label: {
            Image(systemName: manualApproval ? "gearshape.fill" : "gearshape")
                .font(.system(size: 13)).frame(width: 28, height: 32)
        }.buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Conversation options").accessibilityLabel("Conversation options")
            .popover(isPresented: $presented) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Tool execution").font(.system(size: 13, weight: .semibold))
                    Toggle("Ask before running tools", isOn: $manualApproval).toggleStyle(.checkbox)
                    Text("When enabled, your next message requests manual approval. When disabled, the current server setting is preserved.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(18).frame(width: 280)
            }
    }
}
