import AppKit
import SwiftUI
import WorkbenchCore

/// Local-only joint fixture. Shares the production observation shape: typing and
/// streaming publish on one object observed by the conversation and composer.
@MainActor
private final class JointInteractionModel: ObservableObject {
    @Published var selected = 0
    @Published var drafts = ["", ""]
    @Published var tail: [KimiMessage] = []
    @Published var step = 0
    @Published var streaming = false
    @Published var sent = ["", ""]
    private var streamedText = ""
    let histories = (0..<2).map { try! NavigationHistory.conversation(turns: 200, salt: "joint-\($0):").messages }
    var messages: [KimiMessage] { histories[selected] + (selected == 0 ? tail : []) }

    func appendStep() {
        step += 1
        streamedText += "流式片段 \(step)：中文与 English，保持阅读位置和草稿。\n"
        let records: [[String: Any]] = [
            ["id": "joint-live-user", "role": "user", "created_at": "live-0",
             "content": [["type": "text", "text": "固定流式尾部"]]],
            ["id": "joint-live-answer", "role": "assistant", "created_at": "live-1",
             "content": [["type": "text", "text": streamedText]]]
        ]
        tail = try! KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: records))
    }
}

struct JointInteractionPreview: View {
    @StateObject private var model = JointInteractionModel()
    @State private var follow = true
    @State private var error = ""
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("会话", selection: $model.selected) {
                    Text("会话 A · 流式").tag(0); Text("会话 B · 静态").tag(1)
                }.pickerStyle(.segmented).frame(width: 280)
                Button(model.streaming ? "暂停流式" : "继续流式") { model.streaming.toggle() }
                    .disabled(model.step >= 300)
                Text("200 轮历史 · 10 Hz · \(model.step)/300").monospacedDigit()
            }
            Text("仅本地合成内容。向上阅读时输入中文、切换草稿，Return 本地提交，Shift Return 换行。")
                .font(.caption).foregroundStyle(.secondary)
            let session = model.selected
            let key = "joint-\(session)"
            ScrollViewReader { proxy in
                ConversationScrollView(onScroll: {
                    follow = $0; ConversationReadingMemory.shared.following[key] = $0
                }, onContentSizeChange: {
                    if ConversationReadingMemory.shared.following[key] ?? true { proxy.scrollTo("bottom", anchor: .bottom) }
                }) {
                    ConversationTranscript(messages: model.messages, sessionId: key,
                                           isRunning: session == 0 && model.streaming, memoryKey: key)
                    Color.clear.frame(height: 1).id("bottom")
                }.frame(height: 600)
                    .overlay(alignment: .bottom) {
                        ReturnToLatestButton(isVisible: !follow, hasNewReply: session == 0 && model.step > 0) {
                            follow = true; ConversationReadingMemory.shared.following[key] = true
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .task(id: session) {
                        follow = ConversationReadingMemory.shared.following[key] ?? true
                        await Task.yield()
                        if !Task.isCancelled && follow { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: model.step) { _, _ in
                        if #unavailable(macOS 15) {
                            if session == 0 && follow { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                    }
            }
            MessageComposer(text: Binding(get: { model.drafts[session] }, set: { model.drafts[session] = $0 }),
                            accessibilityLabel: "联合验收草稿", canSend: !model.drafts[session].isEmpty,
                            onSend: { model.sent[session] = model.drafts[session]; model.drafts[session] = "" },
                            onFiles: { _ in error = "此 fixture 仅验收文本输入。" }, onError: { error = $0 })
                .id(session).padding(14).frame(width: 700)
            Text(model.sent[session]).lineLimit(2).textSelection(.enabled).font(.caption)
            if !error.isEmpty { Text(error).foregroundStyle(.orange) }
        }.padding(16).frame(width: 1180).preferredColorScheme(.light)
            .task(id: model.streaming) {
                guard model.streaming else { return }
                while model.step < 300 {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    model.appendStep()
                }
                model.streaming = false
            }
    }
}
