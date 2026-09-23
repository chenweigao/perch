import Foundation

/// Labels describe observed tool calls, never their inferred outcome.
public enum ToolPresentation {
    public static func isExploration(_ name: String) -> Bool {
        ["read", "read_file", "readfile", "grep", "search", "glob", "find_files"].contains(name.lowercased())
    }

    public static func action(_ name: String) -> String {
        switch name.lowercased() {
        case "read", "read_file", "readfile": return L("读取")
        case "grep", "search": return L("搜索")
        case "glob", "find_files": return L("查找文件")
        default: return name
        }
    }

    public static func path(_ tool: VisibleTool) -> String? {
        tool.input?["file_path"].string ?? tool.input?["path"].string
    }

    public static func target(_ tool: VisibleTool) -> String {
        if let path = path(tool), !path.isEmpty { return (path as NSString).lastPathComponent }
        return tool.input?["description"].string ?? tool.input?["pattern"].string
            ?? tool.input?["command"].string ?? tool.name
    }

    public static func directory(_ tool: VisibleTool) -> String? {
        guard let path = path(tool), path.contains("/") else { return nil }
        return (path as NSString).deletingLastPathComponent
    }

    /// Compact display only. The full command remains in the tooltip and input.
    public static func compactTarget(_ tool: VisibleTool) -> String {
        if let command = ShellActivity.command(tool) {
            if let description = tool.input?["description"].string, !description.isEmpty {
                return description
            }
            return ShellActivity.parse(command)?.compactTarget ?? L("准备命令环境")
        }
        return target(tool)
    }

    public static func recentTargets(_ tools: [VisibleTool]) -> String {
        var seen = Set<String>(), labels: [String] = []
        for tool in tools.reversed() where !tool.staysVisible {
            let label = compactTarget(tool)
            if seen.insert(label).inserted { labels.append(label) }
            if labels.count == 2 { break }
        }
        return labels.reversed().joined(separator: " · ")
    }

    /// Other tool kinds join summaries without exposing shell arguments or edits.
    public static func summaryTarget(_ tool: VisibleTool) -> String {
        if let path = path(tool) { return (path as NSString).lastPathComponent }
        if isExploration(tool.name), let pattern = tool.input?["pattern"].string { return pattern }
        return tool.name
    }
}
