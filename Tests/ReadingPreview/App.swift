import AppKit
import SwiftUI
import WorkbenchCore

@main
struct ReadingPreviewApp: App {
    @NSApplicationDelegateAdaptor(PreviewDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("回复阅读验收") { ReadingPreview().preferredColorScheme(.light) }
            .defaultSize(width: 920, height: 850)
    }
}
private struct ReadingPreview: View {
    @State private var follow = true
    @State private var scenario = 0
    @State private var model = ""
    @State private var narrow = false
    @State private var streaming = false
    @State private var prefixLength = 0
    @State private var historyPages = 0
    @State private var thoughtSteps = 0
    @State private var phaseSteps = 0
    @State private var todoCompleted = false
    @State private var turnEnded = false
    @State private var nextTurn = false
    // Optional local replay supplied only by the fixture build; no API or remote actions.
    private let replay: KimiConversation? = {
        guard let url = Bundle.main.url(forResource: "scroll-snapshot", withExtension: "json") else { return nil }
        return KimiConversation(try! KimiWire.decode(KimiSnapshot.self, from: Data(contentsOf: url)))
    }()
    private let source = try! String(contentsOf: Bundle.main.url(forResource: "reply-reading", withExtension: "md")!, encoding: .utf8)
    private let wide = "| 内容 | A | B | C | D | E | F |\n| --- | ---: | ---: | ---: | ---: | ---: | ---: |\n| 很长的项目说明 | 10 | 20 | 30 | 40 | 50 | 60 |"
    private var historyMessages: [KimiMessage] {
        var records: [[String: Any]] = []
        for index in (41 - historyPages * 20)...60 {
            records.append(["id": "history-user-\(index)", "role": "user", "created_at": "\(index)-a",
                            "content": [["type": "text", "text": "历史任务 \(index)" + (scenario == 8 && index == 41 ? "\n\n" + String(repeating: source + "\n\n", count: 20) : "")]]])
            let text = "第 \(index) 轮历史回复。\n\n" + (scenario == 8 ? source + "\n\n" : "") + String(repeating: "中文与 English 内容应保持完整，加载更早消息不会卡住，也不会丢失滚动中的历史。", count: 5)
            records.append(["id": "history-answer-\(index)", "role": "assistant", "created_at": "\(index)-b",
                            "content": [["type": "text", "text": text]]])
        }
        return try! KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: records))
    }
    private var scenarioMessages: [KimiMessage] {
        if scenario == 6 {
            let json = """
            [{"id":"earlier","role":"assistant","created_at":"1","content":[{"type":"thinking","thinking":"先检查工作目录"},{"type":"text","text":"开始检查目录。"}]},
             {"id":"overview","role":"assistant","created_at":"2","content":[{"type":"text","text":"两个仓库已核实，接着检查 MR 状态。"},{"type":"tool_use","tool_call_id":"check","tool_name":"Bash"}]},
             {"id":"thought","role":"assistant","created_at":"3","content":[{"type":"thinking","thinking":"这里是独立的思考内容。English reasoning keeps the same light italic style. 收起这段思考后，上方的进度概要仍然可见。"}]}]
            """
            var messages = try! KimiWire.decoder().decode([KimiMessage].self, from: Data(json.utf8))
            for step in 0..<phaseSteps {
                let records: [[String: Any]] = [
                    ["id": "overview-\(step)", "role": "assistant", "created_at": "phase-\(step)-a",
                     "content": [["type": "text", "text": "第 \(step + 1) 阶段概要：这段文字应一直保留，不被下一阶段替换。"]]],
                    ["id": "thought-\(step)", "role": "assistant", "created_at": "phase-\(step)-b",
                     "content": [["type": "thinking", "thinking": "第 \(step + 1) 阶段的新思考出现在概要下方。此前的思考仍可单独展开阅读。"]]]
                ]
                messages += try! KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: records))
            }
            return messages
        }
        let content: [[String: String]]
        if scenario == 3 || scenario == 4 {
            let additions = (0..<thoughtSteps).map { "\n追加思考 \($0 + 1)：这段新增内容应该在固定高度窗口内自动跟随。手动向上阅读时不抢位置，回到底部再恢复跟随。" }.joined()
            content = [["type": "thinking", "thinking": "正在检查模型返回的内容。即使模型只输出思考过程，界面也应该自然换行，保留完整句子。较长的中文与 English reasoning text 应该在固定宽度内换行，不应横向截断，也不应该推着整页不断增长。用户可以在这个固定高度区域内滚动阅读后续内容。结束后没有正文时，这份思考记录仍然可读。" + additions]]
        }
        else if scenario == 5 { content = [["type": "tool_use", "tool_call_id": "t", "tool_name": "read"]] }
        else { content = [["type": "text", "text": "已找到原因：前一版把工具调用前的说明全部折叠了。这段过程说明现在会保留在页面上。"], ["type": "tool_use", "tool_call_id": "t", "tool_name": "read"]] }
        let data = try! JSONSerialization.data(withJSONObject: [["id": "fixture", "role": "assistant", "created_at": "1", "content": content]])
        return try! KimiWire.decoder().decode([KimiMessage].self, from: data)
    }
    private var todoMessages: [KimiMessage] {
        let json = """
        [{"id":"todo","role":"assistant","created_at":"1","content":[{"type":"tool_use","tool_call_id":"plan","tool_name":"TodoList","input":{"todos":[{"title":"定位中文输入问题","status":"done"},{"title":"验收输入与阅读体验","status":"in_progress"},{"title":"完成提交","status":"pending"}]}}]},
         {"id":"result","role":"tool","created_at":"2","content":[{"type":"tool_result","tool_call_id":"plan","is_error":false,"output":"Todo list updated."}]}]
        """
        let state = todoCompleted ? json.replacingOccurrences(of: "in_progress", with: "done").replacingOccurrences(of: "pending", with: "done") : json
        var messages = try! KimiWire.decoder().decode([KimiMessage].self, from: Data(state.utf8))
        if nextTurn {
            messages += try! KimiWire.decoder().decode([KimiMessage].self, from: Data("""
            [{"id":"next-user","role":"user","created_at":"3","content":[{"type":"text","text":"下一轮任务"}]}]
            """.utf8))
        }
        return messages
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("回复阅读验收").font(.headline)
                Spacer()
                Toggle("窄列", isOn: $narrow)
                Toggle("模拟流式回复", isOn: $streaming)
            }.padding(20)
            Picker("场景", selection: $scenario) {
                Text("正文排版").tag(0); Text("运行中").tag(1); Text("没有概要").tag(2)
                Text("只有思考").tag(3); Text("思考结束").tag(4); Text("只有工具").tag(5); Text("概要与思考").tag(6)
                Text("历史分页").tag(7); Text("富文本历史").tag(8)
                if replay != nil { Text("本地快照").tag(9) }
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 12)
            if scenario == 6 { Button("追加下一阶段") { phaseSteps += 1 }.padding(.bottom, 8) }
            if scenario == 3 { Button("追加思考") { thoughtSteps += 1 }.padding(.bottom, 8) }
            if scenario == 1 {
                HStack {
                    Toggle("清单全部完成", isOn: $todoCompleted)
                    Toggle("本轮结束", isOn: $turnEnded)
                    Toggle("开始下一轮", isOn: $nextTurn)
                }.padding(.bottom, 8)
            }
            ModelPicker(models: ModelCatalog.options([
                .object(["provider": .string("demo-a-proxy"), "model": .string("demo-a/claude-example")]),
                .object(["provider": .string("demo-c"), "model": .string("demo-c/claude-example")]),
                .object(["provider": .string("demo-b"), "model": .string("demo-b/kimi-example")])]), selection: $model)
                .padding(.bottom, 12)
            Divider()
            ScrollViewReader { proxy in
            ConversationScrollView(showsScrollIndicator: !follow, onScroll: { follow = $0 }, onContentSizeChange: {
                if follow { proxy.scrollTo("bottom", anchor: .bottom) }
            }) {
                    if scenario == 0 {
                        KimiMarkdown(text: streaming ? String(source.prefix(prefixLength)) : source)
                        ReplyCopyButton(text: source)
                        KimiMarkdown(text: wide)
                    } else if scenario == 9, let replay {
                        ConversationTranscript(messages: replay.displayMessages, sessionId: "offline-replay", isRunning: replay.snapshot.session.busy)
                    } else if scenario == 7 || scenario == 8 {
                        Button(historyPages < 2 ? "加载更早消息" : "已加载全部 60 轮") { follow = false; historyPages += 1 }
                            .disabled(historyPages >= 2).frame(maxWidth: .infinity)
                        ConversationTranscript(messages: historyMessages, sessionId: "history-fixture")
                    } else {
                        ConversationTranscript(messages: scenarioMessages, sessionId: "fixture", isRunning: scenario == 1 || scenario == 3 || scenario == 6)
                    }
                    Color.clear.frame(height: 1).id("bottom")
            }.frame(maxWidth: narrow ? 492 : .infinity)
                .task(id: scenario) { await Task.yield(); proxy.scrollTo("bottom", anchor: .bottom) }
                .overlay(alignment: .bottom) {
                    if !follow { ReturnToLatestButton { follow = true; proxy.scrollTo("bottom", anchor: .bottom) } }
                }
            }
            ConversationActivityBar(activity: ConversationActivity(
                messages: scenario == 1 || scenario == 6 ? todoMessages : [],
                isRunning: (scenario == 1 && !turnEnded) || scenario == 3, isThinking: scenario == 3),
                isRunning: (scenario == 1 && !turnEnded) || scenario == 3, turnID: String(scenario))
                .padding(.horizontal, 32).padding(.bottom, 12)
        }.frame(minWidth: 540, minHeight: 500)
            .task(id: streaming) {
                guard streaming else { return }
                prefixLength = 0
                while prefixLength < source.count && !Task.isCancelled {
                    prefixLength += 35
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                }
                streaming = false
            }
    }
}
private final class PreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        checkNativeTextLayout()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Regression checks for the sizing boundary used by Grid and scrolling text.
@MainActor private func checkNativeTextLayout() {
    let view = ReplyTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
    let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 6
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .paragraphStyle: paragraph]
    let text = String(repeating: "中文与 English 应该自然换行，宽度探测不能改变正在显示的文字。", count: 8)
    view.update(NSAttributedString(string: text, attributes: attributes))
    let containerBefore = view.textContainer!.containerSize
    let wide = view.measure(width: 760)
    let narrow = view.measure(width: 220)
    precondition(narrow.height > wide.height && narrow.width <= 220)
    precondition(view.measure(width: 760) == wide)
    precondition(view.textContainer!.containerSize == containerBefore, "Sizing must not mutate drawing geometry")
    view.update(NSAttributedString(string: "表格列", attributes: attributes))
    let ideal = view.measure(width: nil)
    _ = view.measure(width: 0)
    precondition(view.measure(width: nil) == ideal && ideal.width < 100, "Grid probes must preserve natural column width")
    view.update(NSAttributedString(string: text + "\n追加的一行", attributes: attributes))
    precondition(view.measure(width: 220).height > narrow.height, "Streaming text must invalidate cached height")
}
