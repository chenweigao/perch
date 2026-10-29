import Foundation
import WorkbenchCore

func checkTaskContextFiles() throws {
    let tasks = ["completed", "unknown", "running", "cancelled", "failed", "running"].enumerated().map { index, status in
        KimiTask(id: String(index), kind: "bash", description: "任务 \(index)", status: status)
    }
    let panel = TaskContextTasks(tasks)
    precondition(panel.current.map(\.id) == ["2", "5", "1", "4"] && panel.finished.map(\.id) == ["0", "3"],
                 "History folds only completed/cancelled tasks; running tasks lead, failed and unknown stay visible")
    let text = """
    [Report](docs/报告%20终版.md#结论) [Duplicate](docs/报告%20终版.md)
    ![Diagram](figures/chart.png) \u{0060}notes.txt\u{0060}
    [External](https://example.com/remote.pdf) [Unsafe](javascript:report.md)
    [Source](src/main.swift) [Anchor](#section) \u{0060}~/remote.md\u{0060}
    """
    let raw: [[String: Any]] = [
        ["id": "a", "role": "assistant", "created_at": "", "content": [["type": "text", "text": text]]]
    ]
    let messages = try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    let tools = [
        VisibleTool(id: "write", name: "Write", input: .object(["file_path": .string("notes.txt")]), status: .succeeded),
        VisibleTool(id: "failed", name: "Write", input: .object(["path": .string("failed.md")]), status: .failed),
        VisibleTool(id: "unknown", name: "Write", input: .object(["path": .string("unknown.md")]), status: .returned)
    ]
    let files = TaskContextFiles.collect(messages: messages, tools: tools, directory: "/project")
    precondition(files.first?.path == "/project/notes.txt" && files.first?.written == true)
    precondition(files.filter { $0.path == "/project/docs/报告 终版.md" }.count == 1)
    precondition(files.contains { $0.path == "/project/figures/chart.png" && !$0.written })
    precondition(files.contains { $0.path == "~/remote.md" }, "Remote home references must not expand to this Mac's home")
    precondition(!files.contains { $0.path.contains("example.com") || $0.path.contains("javascript") ||
        $0.path.contains("failed") || $0.path.contains("unknown") || $0.path.hasSuffix(".swift") })
    let linkedOnly = TaskContextFiles.collect(messages: messages, tools: [], directory: "/other")
    precondition(linkedOnly.allSatisfy { !$0.written }, "A link is never proof of a successful write")
    print("PASS: task panel document links, host-relative paths, deduplication and write evidence")
}

func checkTaskContextDetail() {
    let source = SessionReference(hostID: UUID(), terminalID: "s", kind: .kimi)
    let command = KimiTask(id: "bash-1", kind: "bash", description: "构建", status: "running",
                           command: "  \n  gh pr checks 213 --watch\n  --interval 15")
    let finished = KimiTask(id: "bash-2", kind: "bash", description: "测试", status: "completed", command: "npm test")
    let roster = KimiTask(id: "agent-1", kind: "subagent", description: "检索", status: "running", subagentPhase: "working")
    let native = KimiTask(native: NativeSubagent(id: "toolu", kind: "claude", taskId: "task", toolUseIds: ["toolu"],
                                                 description: "核对", status: .running, lastToolName: "Read", canStop: true))
    var snapshot = TaskContextSnapshot(title: "T", directory: "/p", busy: true, messages: [],
                                       tasks: [command, finished, roster, native])
    snapshot.listedTaskIDs = ["bash-1", "bash-2"]

    precondition(command.contextDetailLine == "gh pr checks 213 --watch", "A row names the first command line")
    precondition(native.contextDetailLine == L("最近工具：\("Read")"), "A subagent row names its latest tool")
    precondition(roster.contextDetailLine == nil)
    precondition(snapshot.task(for: TaskContextRoute(source: source, taskID: "bash-2")) == finished)
    precondition(snapshot.task(for: TaskContextRoute(source: source, taskID: "gone")) == nil)
    precondition(snapshot.readsOutput(command) && snapshot.readsOutput(finished))
    precondition(!snapshot.readsOutput(roster) && !snapshot.readsOutput(native),
                 "Only Kimi's persisted task list has output tails")
    precondition(snapshot.stops(command) && !snapshot.stops(finished), "Only a running listed task stops")
    precondition(snapshot.stops(native), "A subagent its runtime marks stoppable stops on its own")
    precondition(!snapshot.stops(roster), "A foreground roster child belongs to the turn's own Stop")

    precondition(TaskContextOutput(text: "tail", bytes: KimiTask.outputTailBytes + 1).truncated)
    precondition(!TaskContextOutput(text: "tail", bytes: KimiTask.outputTailBytes).truncated)
    precondition(!TaskContextOutput(text: "", bytes: nil).truncated)
    let read = TaskContextOutput(KimiTask(id: "bash-1", kind: "bash", description: "", status: "running",
                                          outputPreview: "PASS", outputBytes: 40_000))
    precondition(read == TaskContextOutput(text: "PASS", bytes: 40_000) && read.truncated)
    print("PASS: task detail routes, row detail lines, output and stop capabilities, output tail truncation")
}
