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
            if browser.mode == .file, browser.fileRequest == nil, !browser.path.isEmpty {
                browser.open(browser.path, limit: browser.readLimit, fromEnd: browser.readingTail)
            } else if browser.mode == .git { browser.loadGitStatus() }
            let window = NSWindow(contentRect: NSRect(x: 180, y: 160, width: 960, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = L("文件") + " · Perch"
            window.identifier = NSUserInterfaceItemIdentifier("PerchFileViewer")
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 480, height: 320)
            window.delegate = self
            let hosting = NSHostingController(rootView: FileViewerContent(model: model))
            // The window owns its size; content may impose a minimum, not an ideal size.
            hosting.sizingOptions = [.minSize]
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 960, height: 720))
            window.setFrameUsingName("PerchFileViewer")
            window.setFrameAutosaveName("PerchFileViewer")
            self.window = window
        }
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
        let reference = model.selectedReference
        RemoteFilePanel(browser: model.fileBrowser, showsCloseButton: false,
            onAddContext: model.canQuoteSelection ? { text in
                guard let reference else { return }
                model.appendReviewContext(text, to: reference)
            } : nil,
            onShowDraft: {
                CompanionWindowController.shared.showMain()
                DispatchQueue.main.async { NotificationCenter.default.post(name: .init("PerchFocusComposer"), object: nil) }
            },
            onClose: { model.fileWindow.close() })
            .id(reference?.id)
            .environment(\.locale, appLanguage.resolvedLocale)
            .preferredColorScheme(appAppearance.colorScheme)
    }
}
