import AppKit
import Carbon
import SwiftUI
import WorkbenchCore

@MainActor final class CompanionWindowController {
    static let shared = CompanionWindowController()
    private var panel: NSPanel?
    private weak var model: WorkbenchModel?
    private var openMain: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    func configure(model: WorkbenchModel, openMain: @escaping () -> Void) {
        self.model = model; self.openMain = openMain
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var key = EventHotKeyID()
            guard let event,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr,
                  key.signature == 0x50524348 && key.id == 1 else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in CompanionWindowController.shared.toggle() }
            return noErr
        }, 1, &type, nil, &handler)
        guard installed == noErr else { model.companionShortcutError = L("全局快捷键不可用，可从菜单栏打开任务浮窗。"); return }
        let identifier = EventHotKeyID(signature: 0x50524348, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey), identifier,
                                         GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { model.companionShortcutError = L("全局快捷键不可用，可从菜单栏打开任务浮窗。") }
    }
    func toggle() { if panel?.isVisible == true { panel?.orderOut(nil) } else { show() } }
    func show() {
        guard let model else { return }
        if panel == nil {
            let panel = CompanionPanel(contentRect: NSRect(x: 200, y: 200, width: 420, height: 560),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = L("Perch · 任务浮窗"); panel.isReleasedWhenClosed = false
            panel.level = .floating; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.minSize = NSSize(width: 340, height: 400)
            panel.setFrameAutosaveName("PerchCompanion")
            let hosting = NSHostingController(rootView: CompanionView(model: model, openMain: { [weak self] in self?.showMain() }))
            hosting.sizingOptions = [.minSize]
            panel.contentViewController = hosting
            panel.setContentSize(NSSize(width: 420, height: 560))
            panel.setFrameUsingName("PerchCompanion")
            self.panel = panel
        }
        panel?.makeKeyAndOrderFront(nil)
    }
    func showMain() { openMain?(); NSApp.activate(ignoringOtherApps: true) }
    func shutdown() {
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
        panel?.close(); panel = nil; openMain = nil
    }
}
private final class CompanionPanel: NSPanel { override var canBecomeKey: Bool { true } }

struct CompanionRegistration: View {
    let model: WorkbenchModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.frame(width: 0, height: 0).onAppear {
            CompanionWindowController.shared.configure(model: model, openMain: { openWindow(id: "main") })
        }
    }
}

struct CompanionView: View {
    @Bindable var model: WorkbenchModel
    let openMain: () -> Void
    @AppStorage(AppLanguage.defaultsKey) private var appLanguage: AppLanguage = .system
    @AppStorage(AppAppearance.defaultsKey) private var appAppearance: AppAppearance = .system
    @State private var target: SessionReference?
    @State private var notice = ""
    private var items: [WorkspaceSession] {
        let followed = Set(model.workspace.followedSessions)
        return model.allSessions.filter { !$0.archived && followed.contains($0.reference) }.sorted {
            let left = workspaceTaskPriority($0), right = workspaceTaskPriority($1)
            if left != right { return left < right }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }
    private var selected: WorkspaceSession? { items.first { $0.reference == target } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("关注的任务").font(.headline); Spacer()
                Button("工作台") { model.showHome(); openMain() }
                Button { model.startNewTask(); openMain() } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("交办新任务")
            }
            if items.isEmpty {
                ContentUnavailableView("关注需要持续跟进的任务", systemImage: "pin", description: Text("在项目工作台中点「关注」，它们会出现在这里。"))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(items) { item in
                            if items.first(where: { workspaceTaskPriority($0) == workspaceTaskPriority(item) })?.id == item.id {
                                Text(sectionTitle(item)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            }
                            Button { target = item.reference; notice = "" } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Image(systemName: item.section == .attention ? "exclamationmark.circle" : "circle.dotted")
                                        Text(item.title).lineLimit(2); Spacer()
                                        if target == item.reference { Image(systemName: "checkmark") }
                                    }
                                    if !item.online { Text("状态未同步").foregroundStyle(.secondary) }
                                    if !item.detail.isEmpty && (item.section == .attention || target == item.reference) {
                                        Text(item.detail).lineLimit(2).foregroundStyle(.secondary)
                                    }
                                }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).contentShape(Rectangle())
                            }.buttonStyle(.plain).help("\(item.hostName) · \(item.directory)")
                            Divider()
                        }
                    }
                }
            }
            if let item = selected {
                Text("发送到：\(item.title) · \(item.hostName)").font(.caption).lineLimit(2)
                if item.reference.kind == .terminal {
                    Button("打开会话") { model.open(item); openMain() }.disabled(!item.online)
                } else if item.section == .attention {
                    Button("打开待处理请求") { model.inspect(item); openMain() }.disabled(!item.online)
                } else {
                    TextField("补充一句，下一轮处理…", text: Binding(get: { model.workspace.companionDrafts[item.id] ?? "" }, set: { model.workspace.companionDrafts[item.id] = $0; model.saveWorkspace() }), axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...5)
                    HStack {
                        Button("打开会话") { model.open(item); openMain() }.disabled(!item.online)
                        Spacer()
                        Button("发送") {
                            if model.sendCompanionReply(model.workspace.companionDrafts[item.id] ?? "", to: item.reference) {
                                model.workspace.companionDrafts[item.id] = ""; model.saveWorkspace(); notice = L("已加入该会话的发送队列")
                            } else { notice = L("未发送，请打开会话检查当前状态。") }
                        }.disabled(!item.online || (model.workspace.companionDrafts[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text("⌃⌥P 显示或收起").font(.caption).foregroundStyle(.secondary); Spacer()
                Button("托管") { model.showFollowUps = true; openMain() }.font(.caption)
            }
        }.padding(18).frame(minWidth: 320, minHeight: 360)
            .environment(\.locale, appLanguage.resolvedLocale).preferredColorScheme(appAppearance.colorScheme)
            .onAppear { if target == nil { target = items.first?.reference } }
            .onChange(of: items.map(\.reference)) { _, references in if target.map(references.contains) != true { target = references.first } }
    }
    private func sectionTitle(_ item: WorkspaceSession) -> LocalizedStringKey {
        switch workspaceTaskPriority(item) {
        case 0: return "需要你处理"
        case 1: return "结果待查看"
        case 2: return "进行中"
        case 4: return "状态未同步"
        default: return "其他关注"
        }
    }

}
