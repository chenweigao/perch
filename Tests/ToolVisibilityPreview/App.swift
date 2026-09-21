import AppKit
import SwiftUI
import WorkbenchCore

@main struct ToolVisibilityPreviewApp: App {
    @NSApplicationDelegateAdaptor(ToolPreviewDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("工具展示隔离验收") { ToolPreview().preferredColorScheme(.light) }
            .defaultSize(width: 880, height: 640)
    }
}

private struct ToolPreview: View {
    @State private var phase = 0
    @State private var native = false
    @State private var reduceMotion = false
    @State private var showReturn = false
    @State private var thoughtPreview = false
    @State private var longThought = false
    @State private var model = ""
    private let models = ModelCatalog.options(["Example A", "Example B"].flatMap { provider in
        (1...24).map { index in
            JSONValue.object(["provider": .string(provider), "model": .string("\(provider)/model-\(index)"),
                              "display_name": .string("Model \(index)")])
        }
    })
    private let live = try! KimiWire.decoder().decode([KimiLiveTool].self, from: Data(#"[{"tool_call_id":"read-1","name":"Read","args":{"path":"/fixture/Sample.swift"},"last_progress":"已读取 20 行，正在继续"}]"#.utf8))
    private var messages: [KimiMessage] {
        var rows: [[String: Any]] = [
            ["id": "u", "role": "user", "created_at": "1", "content": [["type": "text", "text": "检查虚构项目中的 Sample.swift"]]],
            ["id": "intro", "role": "assistant", "created_at": "2", "content": [["type": "text", "text": "已找到目标文件，正在核对内容。这段概要应始终可见。"], ["type": "thinking", "thinking": "这段独立思考可以折叠，不影响概要或工具状态。"]]]
        ]
        if thoughtPreview {
            let text = longThought ? String(repeating: "检查每个阶段的输入、工具调用与返回结果。This is a long reasoning preview.\n", count: 18) : "正在检查工具调用记录。"
            rows = [rows[0], ["id": "thought-preview", "role": "assistant", "created_at": "2", "content": [["type": "thinking", "thinking": text]]]]
            return try! KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: rows))
        }
        if (phase >= 1 && phase != 2 && phase != 6 && phase != 7) || native {
            rows.append(["id": "a", "role": "assistant", "created_at": "3", "content": [["type": "tool_use", "tool_call_id": "read-1", "tool_name": "Read", "input": ["path": "/fixture/Sample.swift"]]]])
            rows.append(["id": "duplicate", "role": "assistant", "created_at": "4", "content": [["type": "tool_use", "tool_call_id": "read-1", "tool_name": "Read", "input": ["path": "/fixture/Sample.swift"]]]])
        }
        if phase == 3 {
            rows.append(["id": "progress", "role": "assistant", "created_at": "4", "content": [["type": "text", "text": "读取完成，接下来执行检查。工具摘要应分别留在这段说明的前后。"]]])
            rows.append(["id": "check", "role": "assistant", "created_at": "4", "content": [["type": "tool_use", "tool_call_id": "check-2", "tool_name": "Shell", "input": ["command": "swift test"]]]])
            rows.append(["id": "check-result", "role": "tool", "created_at": "5", "content": [["type": "tool_result", "tool_call_id": "check-2", "is_error": false, "output": "All checks passed (fixture)"]]])
        }
        if [3, 4, 6].contains(phase) {
            rows.append(["id": "r", "role": "tool", "created_at": "5", "content": [["type": "tool_result", "tool_call_id": phase == 6 ? "orphan" : "read-1", "is_error": phase == 4, "output": phase == 4 ? "Permission denied (fixture only)" : "struct Sample {\n    let value = 42\n}\n完整结果的最后一行"]]])
        }
        return try! KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: rows))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("工具展示 · 纯虚构数据").font(.headline)
                Spacer()
                Toggle("OMP / Qoder 历史路径", isOn: $native)
            }
            Picker("阶段", selection: $phase) {
                Text("Live").tag(0); Text("历史重叠").tag(1); Text("交接暂缺").tag(2)
                Text("完成").tag(3); Text("失败").tag(4); Text("断线").tag(5)
                Text("孤立结果").tag(6); Text("待审批").tag(7)
            }.pickerStyle(.segmented)
            HStack {
                ModelPicker(models: models, selection: $model)
                Spacer()
                Toggle("显示回到底部按钮", isOn: $showReturn)
                Toggle("减少动态效果", isOn: $reduceMotion)
            }
            HStack {
                Toggle("思考预览", isOn: $thoughtPreview)
                Toggle("长思考", isOn: $longThought).disabled(!thoughtPreview)
            }
            Divider()
            ConversationScrollView(showsScrollIndicator: true, onScroll: { _ in }, onContentSizeChange: {}) {
                ConversationTranscript(messages: messages, sessionId: thoughtPreview ? "thought-preview-fixture" : "tool-visibility-fixture",
                                       running: !thoughtPreview && native && phase < 2 ? ["read-1"] : [], isRunning: thoughtPreview || phase < 3,
                                       liveTools: !thoughtPreview && !native && phase < 2 ? live : [], online: phase != 5)
                if phase == 7 && !thoughtPreview {
                    Label("需要你的确认（无真实操作）", systemImage: "hand.raised").foregroundStyle(.orange)
                    KimiToolCard(tool: VisibleTool(id: "approval-fixture", name: "Shell", input: .object(["command": .string("printf fixture")]), status: .awaitingApproval))
                }
            }.overlay(alignment: .bottom) {
                ReturnToLatestButton(isVisible: showReturn) { showReturn = false }
            }
            ConversationActivityBar(activity: ConversationActivity(messages: messages, isRunning: thoughtPreview || phase < 3,
                                                                   liveTools: !thoughtPreview && !native && phase < 2 ? live : [],
                                                                   running: !thoughtPreview && native && phase < 2 ? ["read-1"] : [],
                                                                   online: phase != 5, isThinking: phase == 0),
                                    isRunning: thoughtPreview || phase < 3, online: phase != 5)
            Text("无远端连接、无真实消息、无审批按钮；独立 bundle ID 与状态目录。").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 750, minHeight: 500)
            .environment(\.accessibilityReduceMotion, reduceMotion)
    }
}

private final class ToolPreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let state = ProcessInfo.processInfo.environment["TOOL_VISIBILITY_STATE_DIR"] else {
            fatalError("Launch with an isolated TOOL_VISIBILITY_STATE_DIR")
        }
        try! FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        try! Data("fixture only; no connections or user state loaded\n".utf8).write(to: URL(fileURLWithPath: state).appendingPathComponent("launch.txt"))
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
