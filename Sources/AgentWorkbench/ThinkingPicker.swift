import SwiftUI
import WorkbenchCore

/// PI's equal-width reasoning segments. The native range owns pointer, keyboard
/// and accessibility; the pill and raw level labels share its stop centers.
struct ComposerThinkingControl: View {
    let model: AgentModel
    let current: ThinkingLevel?
    let disabled: Bool
    let onSelect: (ThinkingLevel) -> Void
    @UILocalization private var L
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var preview: Int? = nil
    @State private var dragging = false

    private var confirmed: Int? { model.resolve(current).flatMap { model.thinking.firstIndex(of: $0) } }
    private var selected: Int? { preview ?? confirmed }
    var body: some View {
        HStack(spacing: 10) {
            Text(L("推理")).font(.system(size: WorkbenchTheme.Composer.metadata))
                .foregroundStyle(WorkbenchTheme.quiet).fixedSize()
            GeometryReader { geometry in
                let column = geometry.size.width / CGFloat(model.thinking.count)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8).fill(WorkbenchTheme.ink.opacity(0.06))
                    if let selected {
                        RoundedRectangle(cornerRadius: 6).fill(WorkbenchTheme.Composer.raised)
                            .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                            .frame(width: max(0, column - 4), height: 20)
                            .offset(x: CGFloat(selected) * column + 2)
                            .animation(reduceMotion || dragging ? nil : .easeOut(duration: WorkbenchTheme.Composer.motion), value: selected)
                    }
                    HStack(spacing: 0) {
                        ForEach(Array(model.thinking.enumerated()), id: \.element) { index, level in
                            Text(verbatim: level.rawValue)
                                .font(.system(size: WorkbenchTheme.Composer.metadata, weight: index == selected ? .medium : .regular))
                                .foregroundStyle(index == selected ? WorkbenchTheme.ink : WorkbenchTheme.quiet)
                                .lineLimit(1).truncationMode(.tail)
                                .frame(width: column, height: 24)
                        }
                    }.accessibilityHidden(true)
                    ComposerThinkingRange(levels: model.thinking, index: selected ?? 0,
                                          label: L("思考强度"), valueLabel: selected.map { model.thinking[$0].rawValue } ?? L("模型默认"),
                                          disabled: disabled,
                                          preview: { preview = $0; dragging = true },
                                          commit: { index in
                                              dragging = false
                                              guard !disabled else { preview = nil; return }
                                              guard model.thinking.indices.contains(index), index != confirmed else { preview = nil; return }
                                              preview = index
                                              onSelect(model.thinking[index])
                                          })
                        .padding(.horizontal, max(0, column / 2 - 7))
                }
            }.frame(height: WorkbenchTheme.Composer.sliderHeight)
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
        .onChange(of: current) { _, _ in preview = nil }
        .onChange(of: disabled) { _, value in if !value { preview = nil } }
    }
}

private struct ComposerThinkingRange: NSViewRepresentable {
    let levels: [ThinkingLevel]
    let index: Int
    let label: String
    let valueLabel: String
    let disabled: Bool
    let preview: (Int) -> Void
    let commit: (Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ComposerThinkingNSSlider {
        let slider = ComposerThinkingNSSlider()
        slider.cell = ComposerThinkingSliderCell()
        slider.controlSize = .small
        slider.isVertical = false
        slider.sliderType = .linear
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.finished = { [weak slider, weak coordinator = context.coordinator] in
            if let slider { coordinator?.parent.commit(Int(slider.doubleValue.rounded())) }
        }
        slider.setAccessibilityIdentifier("thinking-slider")
        return slider
    }
    func updateNSView(_ slider: ComposerThinkingNSSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = 0; slider.maxValue = Double(max(0, levels.count - 1))
        slider.numberOfTickMarks = levels.count
        slider.allowsTickMarkValuesOnly = true
        slider.doubleValue = Double(index)
        slider.isEnabled = !disabled
        slider.setAccessibilityLabel(label)
        slider.setAccessibilityValueDescription(valueLabel)
    }
    final class Coordinator: NSObject {
        var parent: ComposerThinkingRange
        init(_ parent: ComposerThinkingRange) { self.parent = parent }
        @objc func changed(_ slider: ComposerThinkingNSSlider) {
            let index = Int(slider.doubleValue.rounded())
            parent.preview(index)
            if !slider.trackingSelection { parent.commit(index) }
        }
    }
}

private final class ComposerThinkingNSSlider: NSSlider {
    var trackingSelection = false
    var finished: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        trackingSelection = true
        super.mouseDown(with: event)
        trackingSelection = false
        finished?()
    }
    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        let next: Double
        switch event.keyCode {
        case 123, 125, 121: next = doubleValue - 1
        case 124, 126, 116: next = doubleValue + 1
        case 115: next = minValue
        case 119: next = maxValue
        default: super.keyDown(with: event); return
        }
        doubleValue = min(maxValue, max(minValue, next.rounded()))
        sendAction(action, to: target)
    }
}

private final class ComposerThinkingSliderCell: NSSliderCell {
    // Keep NSSliderCell's layout/tracking pass; suppress only its paint.
    override func drawBar(inside rect: NSRect, flipped: Bool) {}
    override func drawKnob(_ knobRect: NSRect) {}
    override func drawKnob() {}
    override func drawTickMarks() {}
}

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
        let percent = "\(displayedPercent ?? budget.remainingPercent)%"
        return L("上下文剩余约 \(percent)")
    }
    private var tint: Color {
        guard !isStale, let budget else { return .secondary }
        let percent = displayedPercent ?? budget.remainingPercent
        return percent <= 10 ? .red : percent <= 25 ? .orange : .secondary
    }
    private var displayedPercent: Int? { budget.map { 100 - Int(($0.usedFraction * 100).rounded()) } }
    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 6) {
                ZStack {
                    Circle().stroke(WorkbenchTheme.ink.opacity(0.14), lineWidth: 17 * 2.5 / 24)
                        .frame(width: 17 * 18 / 24, height: 17 * 18 / 24)
                    if let budget, !isStale {
                        Circle().trim(from: 0, to: 1 - budget.usedFraction)
                            .stroke(tint, style: StrokeStyle(lineWidth: 17 * 2.5 / 24, lineCap: .round))
                            .frame(width: 17 * 18 / 24, height: 17 * 18 / 24)
                            .rotationEffect(.degrees(-90))
                    } else {
                        Text(isStale ? "–" : "?").font(.system(size: 9, weight: .medium))
                    }
                }.frame(width: 17, height: 17)
                // PI's contract: the remaining percent rides beside the ring at all
                // times; pressure only changes the ink.
                if let budget, !isStale {
                    Text("\(displayedPercent ?? budget.remainingPercent)%")
                        .font(.system(size: WorkbenchTheme.Typography.caption - 1, weight: .semibold))
                        .monospacedDigit()
                }
            }.foregroundStyle(tint)
                .padding(.leading, 5).padding(.trailing, 8).padding(.vertical, 3).frame(minHeight: 24)
                .contentShape(Rectangle())
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
