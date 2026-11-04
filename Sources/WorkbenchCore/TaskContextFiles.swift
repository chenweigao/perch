import Foundation
import Markdown

/// Explicit document links and successful file-write calls. A mention isn't proof
/// of an artifact existing; the normal reader verifies it when opened.
public struct TaskContextFile: Identifiable, Equatable {
    public let path: String
    /// Relative reference when the source was relative, so `referenceCommand`
    /// searches worktrees/directoryHints and subdirectories instead of failing
    /// at a guessed `directory + "/" + reference` path.
    public let reference: String
    public var written: Bool
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public init(path: String, reference: String? = nil, written: Bool) {
        self.path = path
        self.reference = reference ?? path
        self.written = written
    }
}

public enum TaskContextFiles {
    public static func collect(messages: [KimiMessage], tools: [VisibleTool], directory: String) -> [TaskContextFile] {
        var files: [TaskContextFile] = []
        var toolPaths: [String] = []
        for tool in tools.reversed() where tool.status == .succeeded || tool.status == .returned {
            if let raw = tool.input?["file_path"].string ?? tool.input?["path"].string, raw.hasPrefix("/") {
                let clean = (raw as NSString).standardizingPath
                if !toolPaths.contains(clean) { toolPaths.append(clean) }
            }
            for change in tool.input?["changes"].array ?? [] {
                let kind = (change["kind"]["type"].string ?? change["kind"].string)?.lowercased()
                guard kind != "delete" && kind != "remove",
                      let raw = change["move_path"].string ?? change["path"].string, raw.hasPrefix("/") else { continue }
                let clean = (raw as NSString).standardizingPath
                if !toolPaths.contains(clean) { toolPaths.append(clean) }
            }
        }
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
            let isExplicit = reference.path.hasPrefix("/") || reference.path.hasPrefix("~")
            let cleanRelative = isExplicit ? nil : (reference.path as NSString).standardizingPath
            let matchedToolPath = cleanRelative.flatMap { rel in
                toolPaths.first { $0.hasSuffix("/" + rel) }
            }
            let path = matchedToolPath ?? (isExplicit
                ? reference.path : (directory as NSString).appendingPathComponent(reference.path))
            let normalized = path.hasPrefix("~") ? path : (path as NSString).standardizingPath
            guard documentExtensions.contains((normalized as NSString).pathExtension.lowercased()) else { return }
            let ref = matchedToolPath ?? cleanRelative ?? normalized
            if let index = files.firstIndex(where: {
                $0.path == normalized || (cleanRelative != nil && $0.path.hasSuffix("/" + cleanRelative!))
            }) {
                files[index].written = files[index].written || written
            } else if let index = files.firstIndex(where: {
                !$0.reference.hasPrefix("/") && !$0.reference.hasPrefix("~") && normalized.hasSuffix("/" + $0.reference)
            }) {
                files[index] = TaskContextFile(path: normalized, reference: ref, written: files[index].written || written)
            } else if files.count < 40 {
                files.append(TaskContextFile(path: normalized, reference: ref, written: written))
            }
        }
        // Writes with an uncertain or failed result must not acquire an "updated" label.
        for tool in tools.reversed() {
            let name = tool.name.lowercased()
            if tool.status == .succeeded,
               ["write", "write_file", "writefile", "edit", "edit_file", "editfile", "apply_patch", "filechange"].contains(name) {
                if let path = tool.input?["file_path"].string ?? tool.input?["path"].string {
                    add(path, written: true)
                }
                for change in tool.input?["changes"].array ?? [] {
                    let kind = (change["kind"]["type"].string ?? change["kind"].string)?.lowercased()
                    guard kind != "delete" && kind != "remove",
                          let path = change["move_path"].string ?? change["path"].string else { continue }
                    add(path, written: true)
                }
            } else if (tool.status == .succeeded || tool.status == .returned),
                      ["read", "read_file", "readfile", "readmediafile", "view_image"].contains(name),
                      let path = tool.input?["file_path"].string ?? tool.input?["path"].string {
                add(path, written: false)
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
    /// The latest turn's plan in any state, and its edit churn by file: the
    /// 本轮 section's facts that the status line leaves out.
    public let todos: [ConversationTodo]
    public let edits: (perFile: [String: SessionEditStat], total: SessionEditStat)?
    public var taskError: String? = nil
    /// Ids of `tasks` that come from Kimi's persisted task list.
    public var listedTaskIDs: Set<String> = []

    public init(title: String, directory: String, busy: Bool, requests: [TaskContextRequest] = [], failure: String? = nil,
         messages: [KimiMessage], live: [KimiLiveTool] = [], tasks: [KimiTask] = [], native: Bool = false) {
        self.title = title; self.directory = directory; self.busy = busy
        self.requests = requests; self.failure = failure; self.tasks = tasks
        let activity = ConversationActivity(messages: messages, isRunning: busy, liveTools: live,
            running: native ? ToolVisibilityProjection.runningIDs(in: messages, busy: busy) : [],
            pendingCount: requests.count)
        tools = activity.tools
        edits = activity.edits
        todos = ConversationTodo.current(in: Array(messages[(messages.lastIndex(where: \.isUserPrompt) ?? 0)...]))
        files = TaskContextFiles.collect(messages: messages, tools: activity.tools, directory: directory)
    }
}
