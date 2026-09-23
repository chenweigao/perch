import AppKit
import SwiftUI
import WorkbenchCore

@main
struct ReadingPreviewApp: App {
    @NSApplicationDelegateAdaptor(PreviewDelegate.self) private var delegate
    init() {
        if CommandLine.arguments.contains("--check-user-bubbles") {
            NSApplication.shared.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
        }
    }
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
    @State private var showImage = false
    private static let sampleImage: String = {
        let image = NSImage(size: NSSize(width: 240, height: 120))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 240, height: 120).fill()
        image.unlockFocus()
        return image.tiffRepresentation!.base64EncodedString()
    }()
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
        if scenario == 10 { return UserBubbleFixture.messages }
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
            let additions = (0..<thoughtSteps).map { "\n追加思考 \($0 + 1)：这段新增内容应该在固定高度窗口内自动跟随。鼠标放在预览文字上滚动时应移动整页；完整思考在弹窗内阅读。" }.joined()
            content = [["type": "thinking", "thinking": "正在检查模型返回的内容。即使模型只输出思考过程，界面也应该自然换行，保留完整句子。较长的中文与 English reasoning text 应该在固定宽度内换行，不应横向截断，也不应该推着整页不断增长。预览自动显示最新内容，用户可以展开完整思考阅读。结束后没有正文时，这份思考记录仍然可读。" + additions]]
        }
        else if scenario == 5 { content = [["type": "tool_use", "tool_call_id": "t", "tool_name": "read"]] }
        else { content = [["type": "text", "text": "已找到原因：前一版把工具调用前的说明全部折叠了。这段过程说明现在会保留在页面上。"], ["type": "tool_use", "tool_call_id": "t", "tool_name": "read"]] }
        var records: [[String: Any]] = [["id": "fixture", "role": "assistant", "created_at": "1", "content": content]]
        if scenario == 3 && showImage {
            records.insert(["id": "local-image", "role": "assistant", "created_at": "0",
                            "content": [["type": "image", "name": "local-fixture.tiff",
                                         "source": ["kind": "base64", "data": Self.sampleImage]]]], at: 0)
        }
        let data = try! JSONSerialization.data(withJSONObject: records)
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
                Text("历史分页").tag(7); Text("富文本历史").tag(8); Text("用户气泡").tag(10)
                if replay != nil { Text("本地快照").tag(9) }
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 12)
            if scenario == 6 { Button("追加下一阶段") { phaseSteps += 1 }.padding(.bottom, 8) }
            if scenario == 3 {
                HStack {
                    Button("追加思考") { thoughtSteps += 1 }
                    Toggle("本地图片加载", isOn: $showImage)
                }.padding(.bottom, 8)
            }
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
                        if scenario == 3 {
                            ConversationTranscript(messages: historyMessages, sessionId: "thought-scroll-history")
                        }
                        ConversationTranscript(messages: scenarioMessages, sessionId: "fixture", isRunning: scenario == 1 || scenario == 3 || scenario == 6)
                    }
                    Color.clear.frame(height: 1).id("bottom")
            }.frame(maxWidth: narrow ? 492 : .infinity)
                .task(id: scenario) { await Task.yield(); proxy.scrollTo("bottom", anchor: .bottom) }
                .overlay(alignment: .bottom) {
                    ReturnToLatestButton(isVisible: !follow) { follow = true; proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            ConversationActivityBar(activity: ConversationActivity(
                messages: scenario == 1 || scenario == 6 ? todoMessages : [],
                isRunning: (scenario == 1 && !turnEnded) || scenario == 3, isThinking: scenario == 3),
                isRunning: (scenario == 1 && !turnEnded) || scenario == 3)
                .padding(.horizontal, 32).padding(.bottom, 12)
        }.frame(minWidth: 540, minHeight: 500)
            .task(id: streaming) {
                guard streaming else { return }
                if scenario == 3 {
                    thoughtSteps = 0
                    while thoughtSteps < 300 && scenario == 3 && !Task.isCancelled {
                        thoughtSteps += 1
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    }
                    streaming = false
                    return
                }
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
        if CommandLine.arguments.contains("--check-user-bubbles") {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in
                await checkUserMessageLayout()
                NSApp.terminate(nil)
            }
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !CommandLine.arguments.contains("--check-user-bubbles")
    }
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

private enum UserBubbleFixture {
    static let shortText = "Superpowers 太重了，再调研一下"
    static let longText = String(repeating: "请检查用户消息在窄窗口中的布局，保留中文与 English 自然换行、原生文字选择和完整内容，不要横向撑开阅读区。", count: 5)
        + "\n\n只调整宽度、圆角与间距，不增加头像、时间戳或常驻按钮。"
    static let image: String = {
        let image = NSImage(size: NSSize(width: 480, height: 240))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 480, height: 240).fill()
        image.unlockFocus()
        return image.tiffRepresentation!.base64EncodedString()
    }()
    static func message(_ id: String, role: String = "user", content: [[String: Any]]) -> KimiMessage {
        try! KimiWire.decoder().decode(KimiMessage.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "role": role, "created_at": id, "content": content
        ]))
    }
    static let users: [KimiMessage] = [
        message("bubble-short", content: [["type": "text", "text": shortText]]),
        message("bubble-long", content: [["type": "text", "text": longText]]),
        message("bubble-markdown", content: [["type": "text", "text": "请检查这条路径：\n\n/workspace/fixtures/" + String(repeating: "long-directory-name/", count: 12) + "ConversationTranscriptView.swift\n\n- 保留 **原生选择**\n- 不裁切多行文本\n\n```swift\nlet message = \"" + String(repeating: "long source line ", count: 10) + "\"\n```"]]),
        message("bubble-attachments", content: [
            ["type": "text", "text": "请参考附件调整布局。"],
            ["type": "image", "name": "layout-reference.tiff", "source": ["kind": "base64", "data": image]],
            ["type": "file", "name": "layout-requirements.txt"]
        ])
    ]
    static let firstTurn: [KimiMessage] = [users[0],
        message("bubble-tools", role: "assistant", content: [
            ["type": "tool_use", "tool_call_id": "bubble-which", "tool_name": "Bash", "input": ["command": "which superpowers"]],
            ["type": "tool_use", "tool_call_id": "bubble-fetch", "tool_name": "FetchURL", "input": ["url": "https://example.com/skills"]]
        ]),
        message("bubble-results", role: "tool", content: [
            ["type": "tool_result", "tool_call_id": "bubble-which", "output": "Not installed.", "is_error": false],
            ["type": "tool_result", "tool_call_id": "bubble-fetch", "output": "Offline preview fixture.", "is_error": false]
        ]),
        message("bubble-answer", role: "assistant", content: [["type": "text", "text": "我会继续调研更轻量的方案。"]])
    ]
    static var messages: [KimiMessage] { firstTurn + users.dropFirst() }
}

@MainActor private func checkUserMessageLayout() async {
    setbuf(stdout, nil)
    func require(_ condition: Bool, _ message: String, line: UInt = #line) {
        if !condition { fputs("FAIL: \(message) (line \(line))\n", stderr); exit(1) }
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func render<Content: View>(_ content: Content, width: CGFloat, scheme: ColorScheme) async -> (host: NSHostingController<AnyView>, window: NSWindow) {
        let host = NSHostingController(rootView: AnyView(content
            .environment(\.colorScheme, scheme).fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .textBackgroundColor))))
        host.sizingOptions = []
        host.safeAreaRegions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1_200), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.contentViewController = host
        window.orderFront(nil)
        for _ in 0..<4 {
            try? await Task.sleep(for: .milliseconds(50))
            let size = host.sizeThatFits(in: CGSize(width: width, height: 1_000_000))
            window.setContentSize(NSSize(width: width, height: ceil(size.height)))
            host.view.layoutSubtreeIfNeeded()
        }
        return (host, window)
    }
    func snapshot(_ view: NSView, name: String) -> NSBitmapImageRep {
        for text in descendants(view).compactMap({ $0 as? ReplyTextView }) {
            text.layoutManager!.ensureLayout(for: text.textContainer!)
            text.needsDisplay = true
        }
        view.window!.displayIfNeeded()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
        context.scaleBy(x: 2, y: -2)
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.layer!.render(in: context) }
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/\(name).png"))
        return bitmap
    }
    func rect(_ view: NSView, in root: NSView) -> CGRect {
        let frame = view.convert(view.bounds, to: root)
        return root.isFlipped ? frame : CGRect(x: frame.minX, y: root.bounds.height - frame.maxY, width: frame.width, height: frame.height)
    }
    for scheme in [CommandLine.arguments.contains("--dark") ? ColorScheme.dark : .light] {
        var longHeights: [CGFloat: CGFloat] = [:]
        for width: CGFloat in [700, 420] {
            for (index, message) in UserBubbleFixture.users.enumerated() {
                let rendered = await render(KimiMessageView(message: message, tools: [:], api: nil, sessionId: "bubble-check"), width: width, scheme: scheme)
                let root = rendered.host.view
                let textViews = descendants(root).compactMap { $0 as? ReplyTextView }
                require(!textViews.isEmpty, "User message must render native text")
                for text in textViews {
                    let frame = rect(text, in: root)
                    require(text.isSelectable && !text.isEditable, "Native selection must remain available")
                    require(frame.height >= text.measure(width: frame.width).height - 1, "\(message.id) text must not be clipped: frame \(frame), measured \(text.measure(width: frame.width))")
                    if text.enclosingScrollView == nil {
                        require(frame.minX >= width * 0.15 + 14 - 1 && frame.maxX <= width - 14 + 1, "\(message.id) text must stay inside the 85% bubble and padding: \(frame)")
                    }
                }
                if index == 0 {
                    let text = textViews[0], frame = rect(textViews[0], in: root)
                    let ideal = text.measure(width: nil)
                    require(abs(frame.width - ideal.width) <= 1, "Short messages must use their natural width")
                    require(abs(frame.maxX - (width - 14)) <= 1, "Bubble must be right aligned")
                    require(abs(frame.minY - 20) <= 1 && abs(root.bounds.height - frame.maxY - 10) <= 1, "Bubble must have 10 pt vertical padding without extra bottom margin")
                    text.setSelectedRange(NSRange(location: 0, length: (text.string as NSString).length))
                    require((text.string as NSString).substring(with: text.selectedRange()) == UserBubbleFixture.shortText, "Native selection must preserve the complete message")
                    text.setSelectedRange(NSRange(location: 0, length: 0))
                }
                if index == 1 { longHeights[width] = root.bounds.height }
                let bitmap = snapshot(root, name: "\(message.id)-\(Int(width))-\(scheme)")
                let scale = CGFloat(bitmap.pixelsWide) / width
                let textFrame = rect(textViews[0], in: root).intersection(root.bounds)
                var darkest: CGFloat = 1, lightest: CGFloat = 0
                for y in stride(from: Int(textFrame.minY * scale), to: Int(textFrame.maxY * scale), by: 2) {
                    for x in stride(from: Int(textFrame.minX * scale), to: Int(textFrame.maxX * scale), by: 2) {
                        let shade = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!.redComponent
                        darkest = min(darkest, shade); lightest = max(lightest, shade)
                    }
                }
                require(lightest - darkest > 0.45, "Native text must be visible in the rendered \(scheme) snapshot")
                let scanY = Int(24 * scale)
                let paper = bitmap.colorAt(x: bitmap.pixelsWide - Int(7 * scale), y: scanY)!.usingColorSpace(.deviceRGB)!
                let background = bitmap.colorAt(x: 0, y: scanY)!.usingColorSpace(.deviceRGB)!
                require(abs(paper.redComponent - background.redComponent) > 0.015, "Bubble background must remain visible")
                let paperPixels = (0..<bitmap.pixelsWide).filter { x in
                    let color = bitmap.colorAt(x: x, y: scanY)!.usingColorSpace(.deviceRGB)!
                    return abs(color.redComponent - paper.redComponent) < 0.003
                        && abs(color.greenComponent - paper.greenComponent) < 0.003
                        && abs(color.blueComponent - paper.blueComponent) < 0.003
                }
                let bubbleWidth = CGFloat(paperPixels.last! - paperPixels.first! + 1) / scale
                require(bubbleWidth <= width * 0.85 + 1, "Rendered bubble must not exceed 85%: \(bubbleWidth)")
                require(abs(CGFloat(paperPixels.last! + 1) / scale - width) <= 1, "Rendered bubble must be right aligned")
                if index == 0 {
                    require(abs(bubbleWidth - textViews[0].measure(width: nil).width - 28) <= 1, "Short bubble must hug its text and padding")
                }
                if index == 3 {
                    var left = bitmap.pixelsWide, right = 0, pixels = 0
                    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                        for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                            let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                            if color.blueComponent > 0.8 && color.redComponent < 0.2 && color.greenComponent > 0.3 && color.greenComponent < 0.7 {
                                left = min(left, x); right = max(right, x); pixels += 1
                            }
                        }
                    }
                    require(pixels > 1_000, "Image attachment must finish decoding and render")
                    require(CGFloat(left) / scale >= width * 0.15 + 14 - 1 && CGFloat(right) / scale <= width - 14 + 1, "Image must fit inside the bubble")
                }
                print("PASS: \(message.id), \(Int(width)) pt, \(scheme), height \(root.bounds.height)")
                rendered.window.close()
            }
            let rendered = await render(ConversationTranscript(messages: UserBubbleFixture.firstTurn, sessionId: "bubble-spacing-\(width)-\(scheme)"), width: width, scheme: scheme)
            let root = rendered.host.view
            let entries = ConversationTimelineEntry.make(UserBubbleFixture.firstTurn)
            let rows = descendants(root)
            let user = rows.first { $0.identifier?.rawValue == entries[0].id }!
            let process = rows.first { $0.identifier?.rawValue == entries[1].id }!
            require(abs(rect(process, in: root).minY - rect(user, in: root).maxY - 18) <= 1, "Process records must be 18 pt below the user bubble")
            let answer = rows.compactMap { $0 as? ReplyTextView }.first { $0.string == "我会继续调研更轻量的方案。" }!
            require(abs(rect(answer, in: root).minX) <= 1, "Assistant replies must keep their existing left alignment")
            _ = snapshot(root, name: "bubble-transcript-\(Int(width))-\(scheme)")
            rendered.window.close()
        }
        require(longHeights[420]! > longHeights[700]!, "Narrow columns must reflow long prompts")
    }
    print("PASS: user bubble layout, native selection, attachments, process spacing and light/dark snapshots")
}
