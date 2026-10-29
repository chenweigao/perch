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
