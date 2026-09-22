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
}
