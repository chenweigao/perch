import AppKit
import SwiftUI
import WorkbenchCore

/// One native reader window per workspace; macOS owns resizing and frame restoration.
@MainActor final class FileWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private weak var model: WorkbenchModel?

    func show(model: WorkbenchModel) {
        self.model = model
        if window == nil {
            let browser = model.fileBrowser
            if model.pendingFileOutcome == nil, browser.mode == .file, browser.fileRequest == nil, !browser.path.isEmpty {
                browser.open(browser.path, limit: browser.readLimit, fromEnd: browser.readingTail)
            } else if model.pendingFileOutcome == nil, browser.mode == .git { browser.loadGitStatus() }
            let window = FileReaderWindow(contentRect: NSRect(x: 180, y: 160, width: 960, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = L("文件") + " · Perch"
            window.identifier = NSUserInterfaceItemIdentifier("PerchFileViewer")
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 480, height: 320)
            window.delegate = self
            window.browser = browser
            let hosting = NSHostingController(rootView: FileViewerContent(model: model))
            // The window owns its size; content may impose a minimum, not an ideal size.
            hosting.sizingOptions = [.minSize]
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 960, height: 720))
            window.setFrameUsingName("PerchFileViewer")
            window.setFrameAutosaveName("PerchFileViewer")
            self.window = window
        }
        (window as? FileReaderWindow)?.browser = model.pendingFileOutcome == nil ? model.fileBrowser : nil
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        window?.saveFrame(usingName: "PerchFileViewer")
        model?.showFileViewer = false
        model?.fileBrowser.cancel()
        window?.contentViewController = nil
        window = nil
    }
}

struct FileViewerContent: View {
    @Bindable var model: WorkbenchModel
    @AppStorage(AppLanguage.defaultsKey) private var appLanguage: AppLanguage = .system
    @AppStorage(AppAppearance.defaultsKey) private var appAppearance: AppAppearance = .system

    var body: some View {
        if let outcome = model.pendingFileOutcome {
            FileSourcePicker(model: model, outcome: outcome)
                .environment(\.locale, appLanguage.resolvedLocale)
                .preferredColorScheme(appAppearance.colorScheme)
        } else {
            let source = model.fileBrowser.documents.current?.source ?? model.fileBrowser.source
            let item = model.allSessions.first { $0.reference == source && model.agentConnections(for: $0.reference.hostID) != nil }
            RemoteFilePanel(browser: model.fileBrowser, showsCloseButton: false,
                onAddContext: item != nil && source?.kind != .terminal ? { text in
                    guard let source else { return }
                    model.stageArtifactFeedback(text, to: source)
                } : nil,
                onShowDraft: {
                    guard let item else { return }
                    model.open(item)
                    CompanionWindowController.shared.showMain()
                    DispatchQueue.main.async { NotificationCenter.default.post(name: .init("PerchFocusComposer"), object: nil) }
                },
                contextDestination: item?.title,
                onClose: { model.fileWindow.close() })
                .environment(\.locale, appLanguage.resolvedLocale)
                .preferredColorScheme(appAppearance.colorScheme)
        }
    }
}

private struct FileSourcePicker: View {
    let model: WorkbenchModel
    let outcome: GroupOutcome
    @State private var source: SessionReference?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(outcome.title).font(.headline)
            Text("选择文件所在的会话与环境").foregroundStyle(.secondary)
            Picker("来源会话", selection: $source) {
                Text("选择来源环境后预览").tag(SessionReference?.none)
                ForEach(model.allSessions) { item in
                    Text("\(item.title) · \(item.hostName)").tag(Optional(item.reference))
                }
            }
            Button("打开") {
                var selected = outcome; selected.source = source
                model.openWorkspaceFile(selected)
            }.disabled(source == nil).keyboardShortcut(.defaultAction)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Route reader shortcuts only inside this window; main-window conversation keys stay intact.
final class FileReaderWindow: NSWindow {
    weak var browser: RemoteFileBrowser?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard attachedSheet == nil, let browser else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == .command && key == "w" {
            closeTab(); return true
        }
        if modifiers == [.command, .shift], key == "[" || key == "{" || key == "]" || key == "}" {
            browser.selectAdjacentFile(key == "[" || key == "{" ? -1 : 1); return true
        }
        if key == "l" && (modifiers == .command || modifiers == [.command, .shift]) {
            NotificationCenter.default.post(name: .init(modifiers.contains(.shift) ? "PerchGoToFileLine" : "PerchOpenFileLocation"), object: browser)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    private func closeTab() {
        guard let browser, browser.mode == .file, browser.documents.tabs.count > 1 else { close(); return }
        browser.closeFile(browser.path)
    }
}
