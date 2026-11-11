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
    @State private var usesSessionModel = true
    @State private var permissionProvider = ProcessInfo.processInfo.environment["COMPOSER_PREVIEW_AGENT"] ?? SessionKind.kimi.rawValue
    @State private var permissionMode = "default"
    @State private var narrow = false
    @State private var low = false
    @State private var running = false
    @State private var stopping = false
    @State private var offline = false
    @State private var waiting = false
    @State private var emptyModels = false
    @State private var english = false
    @State private var stopCount = 0
    @State private var sendCount = 0
    @State private var lastPayload = "Not sent"
    private let permissionProviders: [SessionKind] = [.kimi, .omp, .qoder, .qoderintl, .dsh, .codex, .claude]
    private var selectedProvider: SessionKind { SessionKind(rawValue: permissionProvider) ?? .kimi }
    private var permissionCapability: PermissionCapability {
        PermissionCatalog.capability(for: selectedProvider, selected: permissionMode)
    }
    private var locale: Locale { Locale(identifier: english ? "en" : "zh-Hans") }
    private var L: LocalizedUIStrings { LocalizedUIStrings(locale: locale) }
    private var canSend: Bool { !offline && !stopping && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var newTask: Bool { ProcessInfo.processInfo.environment["COMPOSER_PREVIEW_NEW_TASK"] == "1" }
    private var combinedPicker: Bool { ProcessInfo.processInfo.environment["COMPOSER_PREVIEW_COMBINED"] != "0" }
    private var usesRuntimeDefault: Bool { [.qoder, .qoderintl].contains(selectedProvider) || (newTask && selectedProvider == .claude) }
    private var disabledReason: String? {
        if offline { return L("连接恢复后可修改设置。") }
        if running { return L("任务运行中，完成或停止后可修改。") }
        return nil
    }
    private func send() {
        let resolved = models.first { $0.id == model }?.resolve(effort)
        lastPayload = "model=\(model) thinking=\(resolved?.rawValue ?? "nil")"
        sendCount += 1; text = ""; running = true
    }
    private let models = [
        AgentModel(id: "fixture/reasoner", provider: "fixture", name: "Reasoner", contextWindow: 272000,
                   thinking: [.low, .medium, .high, .xhigh], defaultThinking: .high, hasVisionCapability: true),
        AgentModel(id: "fixture/deep", provider: "fixture", name: "Deep reasoning", contextWindow: 1048576,
                   thinking: [.low, .high, .max], defaultThinking: .max),
        AgentModel(id: "fixture/plain", provider: "fixture", name: "Plain model", contextWindow: 8192),
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
                Toggle("Waiting", isOn: $waiting).background(ToolbarButtonProbe(id: "waiting"))
                Button("Confirm stopped") { stopping = false; running = false }.disabled(!stopping)
                    .background(ToolbarButtonProbe(id: "confirm-stop"))
                Button("Finish turn") { running = false; stopping = false; text = "Next message" }
                    .background(ToolbarButtonProbe(id: "finish-turn"))
                Button("Draft") { text = "Follow-up" }.background(ToolbarButtonProbe(id: "draft"))
                Text("Sends: \(sendCount) · Stops: \(stopCount)").font(.caption).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 8) {
                MessageComposer(text: $text, placeholder: L("继续此任务…"), canSend: canSend, onSend: send)
                ComposerToolbarLayout {
                    ComposerAddButton(supportsFiles: true) {}
                        .background(ToolbarButtonProbe(id: "add"))
                    ComposerModelPicker(models: emptyModels ? [] : models, modelID: model, thinking: effort,
                                        disabledReason: disabledReason,
                                        unavailableReason: selectedProvider == .claude && !newTask ? L("此 Agent 暂不支持模型与思考设置。") : nil,
                                        sessionModel: "fixture/reasoner", usesSessionModel: usesSessionModel, onUseSessionModel: {
                                            usesSessionModel = true; model = "fixture/reasoner"; effort = models[0].resolve(effort)
                                        }, layout: combinedPicker ? .combined : .split, usesDefaultModel: usesRuntimeDefault && model.isEmpty,
                                        onUseDefaultModel: usesRuntimeDefault ? {
                                            usesSessionModel = false; model = ""; effort = nil
                                        } : nil, scope: L(newTask ? "首条消息生效" : "下一轮生效"),
                                        onSelectModel: { usesSessionModel = false; model = $0.id; effort = $0.resolve(effort) },
                                        onSelectThinking: { effort = $0 })
                        .background(ToolbarButtonProbe())
                        .onChange(of: model + "|" + (effort?.rawValue ?? "nil"), initial: true) { _, value in
                            ToolbarProbe.selection = value
                        }
                    PermissionPicker(provider: selectedProvider, capability: permissionCapability,
                                     disabled: offline, allowsSelection: [.kimi, .qoder, .qoderintl, .claude].contains(selectedProvider)) {
                        permissionMode = $0
                    }.background(ToolbarButtonProbe(id: "permission"))
                    Menu("模板") { Button("示例模板") {} }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .background(ToolbarButtonProbe(id: "templates"))
                    ContextMeter(budget: ContextBudget(used: low ? 95 : 29, limit: 100), isStale: offline)
                    ComposerActionButton(isRunning: running, isStopping: stopping, canSend: canSend,
                                         canStop: running && !offline && !stopping, hasDraft: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                         showsActivity: !offline && !waiting, onSend: send) {
                        stopCount += 1; stopping = true
                    }.background(ToolbarButtonProbe(id: "send"))
                        .onChange(of: stopCount, initial: true) { _, value in ToolbarProbe.stops = value }
                        .onChange(of: sendCount, initial: true) { _, value in ToolbarProbe.sends = value }
                }
            }.padding(12).workbenchControlSurface().frame(width: narrow ? 540 : 840)
                .accessibilityIdentifier("preview-composer").background(ToolbarButtonProbe(id: "composer"))
            Text(lastPayload).font(.caption).accessibilityIdentifier("preview-payload")
                .onChange(of: lastPayload, initial: true) { _, value in ToolbarProbe.payload = value }
        }.padding(20).environment(\.locale, locale)
    }
}
private final class ToolbarDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        if let seed = ProcessInfo.processInfo.environment["COMPOSER_PREVIEW_RECENTS"] {
            UserDefaults.standard.set(seed.split(separator: ",").map { item -> String in
                let parts = item.split(separator: "|", maxSplits: 1)
                return parts.count == 2 ? String(parts[0]) + "\u{0}" + String(parts[1]) : String(item)
            }, forKey: "perch.recentModels")
        }
        if ProcessInfo.processInfo.environment["COMPOSER_TOOLBAR_CHECKS"] == "1" {
            Task { @MainActor in await runToolbarChecks() }
        }
        if let capturePath = ProcessInfo.processInfo.environment["COMPOSER_TOOLBAR_CAPTURE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let window = NSApp.windows.first, let content = window.contentView {
                    // Optionally open a probed control (e.g. the model chip) first.
                    if let openID = ProcessInfo.processInfo.environment["COMPOSER_TOOLBAR_CAPTURE_OPEN"],
                       let view = ToolbarProbe.controls[openID] {
                        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            if let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                                window.sendEvent(event)
                            }
                        }
                        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))
                    }
                    window.displayIfNeeded()
                    content.layoutSubtreeIfNeeded()
                    // A popover (model panel) is its own window: capture it instead.
                    let target = NSApp.windows.last(where: { $0.isVisible }) ?? window
                    let targetContent = target.contentView ?? content
                    target.displayIfNeeded()
                    targetContent.layoutSubtreeIfNeeded()
                    // cacheDisplay drops SwiftUI symbol layers; render the layer tree instead.
                    let scale: CGFloat = 2
                    if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                            pixelsWide: Int(targetContent.bounds.width * scale), pixelsHigh: Int(targetContent.bounds.height * scale),
                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                       let graphics = NSGraphicsContext(bitmapImageRep: bitmap) {
                        let context = graphics.cgContext
                        context.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
                        context.scaleBy(x: scale, y: -scale)
                        targetContent.effectiveAppearance.performAsCurrentDrawingAppearance { targetContent.layer?.render(in: context) }
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: capturePath))
                    }
                    var frames: [String: String] = [:]
                    for (id, view) in ToolbarProbe.controls {
                        frames[id] = NSStringFromRect(view.convert(view.bounds, to: nil))
                    }
                    try? JSONSerialization.data(withJSONObject: frames, options: [.prettyPrinted, .sortedKeys])
                        .write(to: URL(fileURLWithPath: capturePath + ".frames.json"))
                }
                NSApp.terminate(nil)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
