import AppKit
import SwiftUI
import WorkbenchCore

@main struct ToolbarPreviewApp: App {
    @NSApplicationDelegateAdaptor(ToolbarDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Composer toolbar preview") { ToolbarPreview().preferredColorScheme(.light) }
            .defaultSize(width: 900, height: 380)
    }
}
private struct ToolbarPreview: View {
    @State private var text = ""
    @State private var model = "lan/qwen3.8-flash-next"
    @State private var effort: ThinkingLevel? = .xhigh
    @State private var manual = false
    @State private var narrow = false
    @State private var low = false
    @State private var running = false
    @State private var stopping = false
    @State private var offline = false
    @State private var stopCount = 0
    @State private var sendCount = 0
    private var canSend: Bool { !offline && !stopping && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func send() { sendCount += 1; text = ""; running = true }
    private let models = ModelCatalog.options([
        .object(["provider": .string("lan"), "model": .string("lan/qwen3.8-flash-next")]),
        .object(["provider": .string("fixture"), "model": .string("fixture/a-very-long-model-name-for-narrow-window-layout-validation")])])
    var body: some View {
        VStack(spacing: 24) {
            HStack { Text("Offline layout preview"); Spacer(); Toggle("Narrow", isOn: $narrow); Toggle("Low context", isOn: $low) }
            HStack {
                Toggle("Running", isOn: $running)
                Toggle("Offline", isOn: $offline)
                Button("Confirm stopped") { stopping = false; running = false }.disabled(!stopping)
                Text("Sends: \(sendCount) · Stops: \(stopCount)").font(.caption).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 12) {
                MessageComposer(text: $text, canSend: canSend, onSend: send)
                HStack(spacing: 10) {
                    Button {} label: { Image(systemName: "plus").font(.system(size: 17)).frame(width: 23, height: 25) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Add images or files").accessibilityLabel("Add images or files")
                    ModelPicker(models: models, selection: $model)
                    ThinkingPicker(model: AgentModel(id: model, provider: "lan", name: model,
                                                     thinking: [.low, .medium, .high, .xhigh], defaultThinking: .xhigh),
                                   current: effort, disabled: false) { effort = $0 }
                    Spacer(minLength: 8)
                    ContextMeter(budget: ContextBudget(used: low ? 95 : 13, limit: 100))
                    ComposerOptionsButton(manualApproval: $manual)
                    ComposerActionButton(isRunning: running, isStopping: stopping, canSend: canSend,
                                         canStop: running && !offline && !stopping, onSend: send) {
                        stopCount += 1; stopping = true
                    }
                }
            }.padding(14).workbenchControlSurface().frame(width: narrow ? 540 : 840)
        }.padding(20)
    }
}
private final class ToolbarDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
