import AppKit
import SwiftUI
import WorkbenchCore

@main struct ActivityPreviewApp: App {
    @NSApplicationDelegateAdaptor(ActivityDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Task activity preview") { ActivityPreview().preferredColorScheme(.light) }
            .defaultSize(width: 900, height: 410)
    }
}
private struct ActivityPreview: View {
    @State private var phase = "Tools"
    @State private var narrow = false
    @State private var reviewCount = 0
    @State private var reconnectCount = 0
    @State private var turn = 1
    private var busy: Bool { phase != "Done" && phase != "Failed" }
    private var messages: [KimiMessage] {
        var rows: [[String: Any]] = [
            ["id": "u\(turn)", "role": "user", "created_at": "", "content": [["type": "text", "text": "Inspect a fixture project"]]]
        ]
        if phase != "Thinking" {
            let todos: [[String: String]] = [
                ["title": "Inspect the existing layout", "status": "done"],
                ["title": "Check the activity presentation", "status": phase == "Done" ? "done" : "in_progress"],
                ["title": "Verify keyboard and narrow layouts", "status": phase == "Done" ? "done" : "pending"]]
            rows += [
                ["id": "plan", "role": "assistant", "created_at": "", "content": [["type": "tool_use", "tool_call_id": "plan", "tool_name": "TodoList", "input": ["todos": todos]]]],
                ["id": "plan-result", "role": "tool", "created_at": "", "content": [["type": "tool_result", "tool_call_id": "plan", "is_error": false, "output": "Plan updated"]]],
                ["id": "tool", "role": "assistant", "created_at": "", "content": [["type": "tool_use", "tool_call_id": "read", "tool_name": "Read", "input": ["path": "/fixture/Sample.swift"]]]]
            ]
            if ["Done", "Failed", "Responding"].contains(phase) {
                rows.append(["id": "result", "role": "tool", "created_at": "", "content": [["type": "tool_result", "tool_call_id": "read", "is_error": phase == "Failed", "output": phase == "Failed" ? "Permission denied (fixture)" : "Read complete"]]])
            }
        }
        return try! KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: rows))
    }
    private let live = try! KimiWire.decoder().decode([KimiLiveTool].self, from: Data(#"[{"tool_call_id":"read","name":"Read","args":{"path":"/fixture/Sample.swift"},"last_progress":"Read 20 lines; checking imports"}]"#.utf8))
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack { Text("Local fixture · No agent connections").font(.headline); Spacer(); Toggle("Narrow", isOn: $narrow) }
            Picker("Scenario", selection: $phase) {
                ForEach(["Thinking", "Tools", "Approval", "Offline", "Stopping", "Responding", "Done", "Failed"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented)
            Text("Reviews: \(reviewCount) · Reconnects: \(reconnectCount) · Turn: \(turn)")
            Button("Next turn") { turn += 1; phase = "Thinking" }
            Spacer()
            ConversationActivityBar(activity: ConversationActivity(
                messages: messages, isRunning: busy,
                liveTools: ["Tools", "Approval", "Offline", "Stopping"].contains(phase) ? live : [],
                online: phase != "Offline", isThinking: phase == "Thinking", isResponding: phase == "Responding",
                pendingCount: phase == "Approval" ? 1 : 0, isStopping: phase == "Stopping"),
                isRunning: busy, turnID: String(turn), online: phase != "Offline", pendingCount: phase == "Approval" ? 1 : 0,
                onReview: { reviewCount += 1 }, onReconnect: { reconnectCount += 1 })
                .frame(width: narrow ? 340 : 840)
            Text("Continue this task, or share a new idea…").foregroundStyle(.secondary)
                .frame(width: narrow ? 308 : 808, height: 64, alignment: .topLeading).padding(16).workbenchControlSurface()
        }.padding(24)
    }
}
private final class ActivityDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
