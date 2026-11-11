import AppKit
import SwiftUI

@main
struct ComposerPreviewApp: App {
    @NSApplicationDelegateAdaptor(ComposerPreviewDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("输入验收") { ComposerPreview().preferredColorScheme(ProcessInfo.processInfo.environment["CITE_PREVIEW_DARK"] == "1" ? .dark : .light) }
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
    private let citationToken = "@cite(\"deadbeef\")"
    private let citationText = "> 整轮只保留一个执行中的过程头。\n> 思考、工具和中间进展都放在同一个折叠区域。\n> 最终回答留在外面，方便连续阅读。"
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
                                onFiles: { files.append(contentsOf: $0) }, onError: { error = $0 },
                                citations: [ComposerCitation(token: citationToken, label: "引用 · 3 行", missingMessage: "引用内容不存在", load: { citationText })]).id(draftID)
                HStack {
                    Button("引用上下文") { drafts[draftID] += citationToken + " " }.buttonStyle(.borderless)
                    Text("Return 发送 · Shift Return 换行").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }.padding(14).overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.black.opacity(0.12)))
            if !error.isEmpty { Text(error).foregroundStyle(.orange) }
        }.padding(24).onReceive(timer) { _ in tick += 1 }.frame(minWidth: 500, minHeight: 420)
            .onAppear {
                if ProcessInfo.processInfo.environment["CITE_PREVIEW_CAPTURE"] != nil {
                    drafts[0] = citationToken + " \n请把这段上下文接着讲清楚，保留刚才的设计。"
                }
            }
    }
}
private final class ComposerPreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let path = ProcessInfo.processInfo.environment["CITE_PREVIEW_CAPTURE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let window = NSApp.windows.first(where: { $0.contentView != nil }), let view = window.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
