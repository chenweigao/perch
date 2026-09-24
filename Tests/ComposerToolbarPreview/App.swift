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
    @State private var text = "Preview message"
    @State private var model = "fixture/reasoner"
    @State private var effort: ThinkingLevel? = .xhigh
    @State private var permissionProvider = ProcessInfo.processInfo.environment["COMPOSER_PREVIEW_AGENT"] ?? SessionKind.kimi.rawValue
    @State private var permissionMode = "manual"
    @State private var narrow = false
    @State private var low = false
    @State private var running = false
    @State private var stopping = false
    @State private var offline = false
    @State private var emptyModels = false
    @State private var english = false
    @State private var stopCount = 0
    @State private var sendCount = 0
    @State private var lastPayload = "Not sent"
    private let permissionProviders: [SessionKind] = [.kimi, .omp, .qoder, .dsh, .codex]
    private var selectedProvider: SessionKind { SessionKind(rawValue: permissionProvider) ?? .kimi }
    private var permissionCapability: PermissionCapability {
        PermissionCatalog.capability(for: selectedProvider, selected: permissionMode)
    }
    private var locale: Locale { Locale(identifier: english ? "en" : "zh-Hans") }
    private var L: LocalizedUIStrings { LocalizedUIStrings(locale: locale) }
    private var canSend: Bool { !offline && !stopping && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var disabledReason: String? {
        if offline { return L("连接恢复后可修改设置。") }
        if running && selectedProvider != .kimi { return L("任务运行中，完成或停止后可修改。") }
        return nil
    }
    private func send() {
        let resolved = models.first { $0.id == model }?.resolve(effort)
        lastPayload = "model=\(model) thinking=\(resolved?.rawValue ?? "nil")"
        sendCount += 1; text = ""; running = true
    }
    private let models = [
        AgentModel(id: "fixture/reasoner", provider: "fixture", name: "Reasoner", thinking: [.low, .medium, .high, .xhigh], defaultThinking: .high),
        AgentModel(id: "fixture/deep", provider: "fixture", name: "Deep reasoning", thinking: [.low, .high, .max], defaultThinking: .max),
        AgentModel(id: "fixture/plain", provider: "fixture", name: "Plain model"),
        AgentModel(id: "fixture/long", provider: "extended", name: "A very long model name for narrow window layout validation", thinking: ThinkingLevel.allCases, defaultThinking: .auto),
        AgentModel(id: "fixture/default", provider: "extended", name: "Runtime default", thinking: [.low, .high])
    ]
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Offline layout preview"); Spacer()
                Toggle("Narrow", isOn: $narrow).accessibilityIdentifier("preview-narrow")
                    .background(ToolbarButtonProbe(id: "narrow"))
                Toggle("English", isOn: Binding(get: { english }, set: {
                    AppLanguage.applyToSystem($0 ? .en : .zhHans); english = $0
                })).accessibilityIdentifier("preview-english")
                    .background(ToolbarButtonProbe(id: "english"))
                Toggle("Low context", isOn: $low)
            }
            HStack {
                Picker("Agent", selection: $permissionProvider) {
                    ForEach(permissionProviders, id: \.rawValue) { provider in Text(provider.label).tag(provider.rawValue) }
                }.frame(width: 180).accessibilityIdentifier("preview-agent")
                    .onChange(of: permissionProvider, initial: true) { _, value in
                        guard let provider = SessionKind(rawValue: value),
                              let mode = PermissionCatalog.safeDefault(for: provider) else { return }
                        permissionMode = mode
                    }
                Toggle("Empty model list", isOn: $emptyModels).accessibilityIdentifier("preview-empty-models")
                    .background(ToolbarButtonProbe(id: "empty"))
                Text("Next: \(model) · \(effort?.rawValue ?? "nil")")
                    .font(.caption).textSelection(.enabled).accessibilityIdentifier("preview-selection")
            }
            HStack {
                Toggle("Running", isOn: $running).accessibilityIdentifier("preview-running")
                    .background(ToolbarButtonProbe(id: "running"))
                Toggle("Offline", isOn: $offline).accessibilityIdentifier("preview-offline")
                    .background(ToolbarButtonProbe(id: "offline"))
                Button("Confirm stopped") { stopping = false; running = false }.disabled(!stopping)
                Text("Sends: \(sendCount) · Stops: \(stopCount)").font(.caption).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 12) {
                MessageComposer(text: $text, canSend: canSend, onSend: send)
                ComposerToolbarLayout {
                    ComposerAddButton(supportsFiles: true) {}
                    ComposerModelPicker(models: emptyModels ? [] : models, modelID: model, thinking: effort,
                                        disabledReason: disabledReason,
                                        unavailableReason: selectedProvider == .qoder ? L("此 Agent 暂不支持模型与思考设置。") : nil,
                                        sessionModel: "fixture/reasoner", onUseSessionModel: {
                                            model = "fixture/reasoner"; effort = models[0].resolve(effort)
                                        }, scope: L(selectedProvider == .kimi ? "下一条消息生效" : "下一轮生效"),
                                        onSelectModel: { model = $0.id; effort = $0.resolve(effort) },
                                        onSelectThinking: { effort = $0 })
                        .background(ToolbarButtonProbe())
                        .onChange(of: model + "|" + (effort?.rawValue ?? "nil"), initial: true) { _, value in
                            ToolbarProbe.selection = value
                        }
                    PermissionPicker(provider: selectedProvider, capability: permissionCapability,
                                     disabled: offline, allowsSelection: selectedProvider == .kimi || selectedProvider == .qoder) {
                        permissionMode = $0
                    }.background(ToolbarButtonProbe(id: "permission"))
                    ContextMeter(budget: ContextBudget(used: low ? 95 : 13, limit: 100))
                    ComposerActionButton(isRunning: running, isStopping: stopping, canSend: canSend,
                                         canStop: running && !offline && !stopping, onSend: send) {
                        stopCount += 1; stopping = true
                    }.background(ToolbarButtonProbe(id: "send"))
                }
            }.padding(14).workbenchControlSurface().frame(width: narrow ? 540 : 840)
                .accessibilityIdentifier("preview-composer").background(ToolbarButtonProbe(id: "composer"))
            Text(lastPayload).font(.caption).accessibilityIdentifier("preview-payload")
                .onChange(of: lastPayload, initial: true) { _, value in ToolbarProbe.payload = value }
        }.padding(20).environment(\.locale, locale)
    }
}
private final class ToolbarDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        if ProcessInfo.processInfo.environment["COMPOSER_TOOLBAR_CHECKS"] == "1" {
            Task { @MainActor in await runToolbarChecks() }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
