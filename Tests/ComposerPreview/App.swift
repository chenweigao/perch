import AppKit
import SwiftUI

@main
struct ComposerPreviewApp: App {
    @NSApplicationDelegateAdaptor(ComposerPreviewDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("输入验收") { ComposerPreview().preferredColorScheme(.light) }
            .defaultSize(width: 760, height: 500)
    }
}
private struct ComposerPreview: View {
    @State private var session = 0
    @State private var drafts = ["", ""]
    @State private var tick = 0
    @State private var sent: [String] = []
    @State private var files: [URL] = []
    @State private var error = ""
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("输入验收 · 隔离本地草稿").font(.headline)
                Spacer()
                Text("流式刷新 \(tick)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Picker("草稿", selection: $session) { Text("会话一").tag(0); Text("会话二").tag(1) }.pickerStyle(.segmented)
            Text("输入中文、选择候选、Return 发送、Shift Return 换行；切换会话保留草稿。这里只有本地测试，不会联系远端。").font(.callout).foregroundStyle(.secondary)
            ScrollView { VStack(alignment: .leading, spacing: 8) { ForEach(Array(sent.enumerated()), id: \.offset) { item in Text(item.element).textSelection(.enabled) } }.frame(maxWidth: .infinity, alignment: .leading) }
            VStack(alignment: .leading, spacing: 10) {
                if !files.isEmpty { ScrollView(.horizontal) { HStack { ForEach(files, id: \.self) { file in ComposerAttachment(file: file) { files.removeAll { $0 == file } } } } } }
                let draftID = session
                MessageComposer(text: Binding(get: { drafts[draftID] }, set: { drafts[draftID] = $0 }),
                                accessibilityLabel: "测试消息", canSend: !drafts[draftID].isEmpty || !files.isEmpty,
                                onSend: { sent.append(drafts[draftID]); drafts[draftID] = ""; files = [] },
                                onFiles: { files.append(contentsOf: $0) }, onError: { error = $0 }).id(draftID)
                HStack { Text("Return 发送 · Shift Return 换行 · 可粘贴图片").font(.caption).foregroundStyle(.secondary); Spacer(); Text("\(drafts[draftID].count) 字符").font(.caption) }
            }.padding(14).overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.black.opacity(0.12)))
            if !error.isEmpty { Text(error).foregroundStyle(.orange) }
        }.padding(24).onReceive(timer) { _ in tick += 1 }.frame(minWidth: 500, minHeight: 420)
    }
}
private final class ComposerPreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
