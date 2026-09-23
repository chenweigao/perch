import Foundation

/// Describes the operation after shell setup, without treating words in paths or
/// quoted arguments as evidence of a build/test. This is display metadata only.
struct ShellActivity {
    let executable: String
    let arguments: [String]

    static func command(_ tool: VisibleTool) -> String? {
        guard ["bash", "shell", "exec_command", "run_command"].contains(tool.name.lowercased()) else { return nil }
        return tool.input?["command"].string ?? tool.input?["cmd"].string
    }

    static func parse(_ command: String) -> Self? {
        for words in segments(command) {
            var words = words
            while let first = words.first, first.contains("="), !first.hasPrefix("-") { words.removeFirst() }
            while let first = words.first, ["env", "command", "exec"].contains(first) {
                words.removeFirst()
                while let value = words.first, value.contains("=") { words.removeFirst() }
            }
            guard let first = words.first else { continue }
            let executable = (first as NSString).lastPathComponent.lowercased()
            if ["cd", "export", "source", ".", "set"].contains(executable) { continue }
            if ["bash", "sh", "zsh"].contains(executable), words.count >= 3,
               ["-c", "-lc"].contains(words[1]) { return parse(words[2]) }
            return Self(executable: executable, arguments: Array(words.dropFirst()))
        }
        return nil
    }

    var category: String? {
        let subcommand = arguments.first(where: { !$0.hasPrefix("-") }) ?? ""
        if ["sleep", "wait"].contains(executable) { return "wait" }
        if ["pytest", "xctest", "unittest"].contains(executable) { return "test" }
        if ["swift", "cargo", "go", "npm", "pnpm", "yarn", "bun", "make"].contains(executable) {
            let action = subcommand == "run" ? arguments.dropFirst().first : subcommand
            if ["test", "check", "lint", "build"].contains(action ?? "") { return action }
        }
        if ["python", "python3"].contains(executable), arguments.first == "-m",
           ["pytest", "unittest"].contains(arguments.dropFirst().first ?? "") { return "test" }
        if executable == "xcodebuild" { return arguments.contains("test") ? "test" : "build" }
        if executable == "swiftc" { return "build" }
        if ["swiftlint", "eslint", "ruff"].contains(executable) { return "lint" }
        if executable == "git" { return "git" }
        if ["rg", "grep", "find", "ls", "cat", "head", "tail", "sed"].contains(executable) { return "read" }
        return nil
    }

    var phase: ActivityNarrativePhase {
        switch category {
        case "test", "check", "lint", "build": return .validating
        case "git": return ["status", "diff", "log", "show", "ls-files"].contains(arguments.first ?? "") ? .exploring : .integrating
        case "read": return .exploring
        default: return .mixed
        }
    }

    var headline: String {
        switch category {
        case "wait": return L("等待任务继续")
        case "test": return L("运行测试")
        case "check", "lint": return L("检查代码")
        case "build": return L("构建项目")
        case "git": return phase == .exploring ? L("查看 Git 状态与改动") : L("执行 Git 操作")
        case "read": return L("查看文件与代码")
        default: return L("执行命令")
        }
    }

    var compactTarget: String {
        ["git", "swift", "cargo", "go", "npm", "pnpm", "yarn", "bun"].contains(executable)
            ? ([executable] + arguments.prefix(1)).joined(separator: " ") : executable
    }

    private static func segments(_ command: String) -> [[String]] {
        var result: [[String]] = [], words: [String] = [], word = ""
        var quote: Character?, escaped = false
        func finishWord() {
            if !word.isEmpty { words.append(word); word = "" }
        }
        for character in command {
            if escaped { word.append(character); escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; continue }
            if let current = quote {
                if character == current { quote = nil } else { word.append(character) }
            } else if character == "'" || character == "\"" { quote = character }
            else if [";", "&", "|", "\n"].contains(character) {
                finishWord()
                if !words.isEmpty { result.append(words); words = [] }
            } else if character.isWhitespace { finishWord() }
            else { word.append(character) }
        }
        finishWord()
        if !words.isEmpty { result.append(words) }
        return result
    }
}
