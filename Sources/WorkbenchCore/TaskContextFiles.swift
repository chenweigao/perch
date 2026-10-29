import Foundation
import Markdown

/// Explicit document links and successful file-write calls. A mention isn't proof
/// of an artifact existing; the normal reader verifies it when opened.
public struct TaskContextFile: Identifiable, Equatable {
    public let path: String
    public var written: Bool
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
}

public enum TaskContextFiles {
    public static func collect(messages: [KimiMessage], tools: [VisibleTool], directory: String) -> [TaskContextFile] {
        var files: [TaskContextFile] = []
        func add(_ raw: String, written: Bool = false, link: Bool = false) {
            let reference: ConversationFileReference?
            if let url = URL(string: raw), url.scheme == "perch-file" {
                reference = ConversationFileReference(url: url)
            } else {
                if link {
                    // Decode once, after separating URL syntax. Foundation's
                    // automatic encoding can double-escape mixed Unicode/% paths.
                    let path = String(raw.prefix { $0 != "#" && $0 != "?" })
                    guard !path.isEmpty, !path.hasPrefix("//") else { return }
                    reference = ConversationFileReference(text: path.removingPercentEncoding ?? path)
                } else { reference = ConversationFileReference(text: raw) }
            }
            guard let reference, !reference.path.isEmpty else { return }
            let path = reference.path.hasPrefix("/") || reference.path.hasPrefix("~")
                ? reference.path : (directory as NSString).appendingPathComponent(reference.path)
            let normalized = path.hasPrefix("~") ? path : (path as NSString).standardizingPath
            guard documentExtensions.contains((normalized as NSString).pathExtension.lowercased()) else { return }
            if let index = files.firstIndex(where: { $0.path == normalized }) {
                files[index].written = files[index].written || written
            } else if files.count < 40 {
                files.append(TaskContextFile(path: normalized, written: written))
            }
        }
        // Writes with an uncertain or failed result must not acquire an "updated" label.
        for tool in tools.reversed() where tool.status == .succeeded {
            if ["write", "write_file", "writefile", "edit", "edit_file", "editfile"].contains(tool.name.lowercased()),
               let path = tool.input?["file_path"].string ?? tool.input?["path"].string {
                add(path, written: true)
            }
        }
        var remaining = 131_072
        for message in messages.suffix(160).reversed() where message.role == "assistant" || message.role == "user" {
            for part in message.content where part.type == "text" {
                guard remaining > 0 else { break }
                let text = String((part.visibleText ?? "").prefix(remaining))
                remaining -= text.count
                func visit(_ node: Markup) {
                    if let link = node as? Link, let destination = link.destination { add(destination, link: true) }
                    if let image = node as? Markdown.Image, let source = image.source { add(source, link: true) }
                    if let code = node as? InlineCode { add(code.code) }
                    for child in node.children { visit(child) }
                }
                visit(Document(parsing: text))
                for reference in ProjectFileReference.references(in: text) { add(reference.path) }
            }
        }
        return files
    }
    private static let documentExtensions: Set<String> = [
        "md", "markdown", "mdown", "txt", "rst", "pdf", "html", "htm",
        "csv", "tsv", "xlsx", "xls", "docx", "doc", "pptx", "ppt",
        "png", "jpg", "jpeg", "gif", "webp", "svg", "heic"
    ]
}

/// Only confirmed completion/cancellation moves out of the panel's active list.
/// Failed and unknown tasks remain available without opening history.
public struct TaskContextTasks {
    public let current: [KimiTask]
    public let finished: [KimiTask]
    public init(_ tasks: [KimiTask]) {
        finished = tasks.filter { $0.status == "completed" || $0.status == "cancelled" }
        current = tasks.filter { $0.status != "completed" && $0.status != "cancelled" }
            .sorted { $0.isRunning && !$1.isRunning }
    }
}

public struct TaskContextRequest: Identifiable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

public struct TaskContextSnapshot {
    public let title: String
    public let directory: String
    public let busy: Bool
    public let requests: [TaskContextRequest]
    public let failure: String?
    public let tools: [VisibleTool]
    public let tasks: [KimiTask]
    public let files: [TaskContextFile]
    public var taskError: String? = nil

    public init(title: String, directory: String, busy: Bool, requests: [TaskContextRequest] = [], failure: String? = nil,
         messages: [KimiMessage], live: [KimiLiveTool] = [], tasks: [KimiTask] = [], native: Bool = false) {
        self.title = title; self.directory = directory; self.busy = busy
        self.requests = requests; self.failure = failure; self.tasks = tasks
        let activity = ConversationActivity(messages: messages, isRunning: busy, liveTools: live,
            running: native ? ToolVisibilityProjection.runningIDs(in: messages, busy: busy) : [],
            pendingCount: requests.count)
        tools = activity.tools
        files = TaskContextFiles.collect(messages: messages, tools: activity.tools, directory: directory)
    }
}
