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
                        if level == current { Label(level.label, systemImage: "checkmark") } else { Text(level.label) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain").font(.system(size: 10))
                    Text(current.map(\.label) ?? model.defaultThinking.map { "\($0.label)（默认）" } ?? "思考强度")
                        .font(.system(size: 12))
                }.foregroundStyle(.secondary)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(disabled)
                .help("思考强度只影响下一轮；可选项来自该模型声明的范围")
                .accessibilityLabel("选择思考强度")
        } else if model != nil {
            Text("该模型无思考强度").font(.system(size: 11)).foregroundStyle(.tertiary)
                .help("此模型未声明可选的思考强度，设置该值不会生效")
        }
    }
}

/// Remaining context for the current session. Absent until the runtime reports a
/// window, since zero of zero would read as an empty context rather than unknown.
struct ContextMeter: View {
    let budget: ContextBudget?

    var body: some View {
        if let budget {
            HStack(spacing: 5) {
                Gauge(value: budget.usedFraction) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity).frame(width: 46).tint(tint(budget.pressure))
                Text("余 \(budget.remainingPercent)%").font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(budget.pressure == .comfortable ? .secondary : tint(budget.pressure))
            }.help(budget.summary + "\n" + budget.detail)
                .accessibilityLabel(budget.summary)
        } else {
            Text("上下文余量未知").font(.system(size: 11)).foregroundStyle(.tertiary)
                .help("运行时尚未上报上下文用量，通常在第一轮结束后出现")
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
