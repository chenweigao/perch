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

    private static let leadingKeywords: Set<String> =
        ["do", "then", "else", "elif", "if", "while", "until", "!", "{", "(", "time"]
    private static let structuralKeywords: Set<String> =
        ["for", "select", "case", "in", "done", "fi", "esac", "}", ")"]

    /// Commands recur across a session's snapshots; the parse is pure, so keep a
    /// bounded memo rather than re-tokenizing every presentation update.
    private enum ParsedCommand {
        case parsed(ShellActivity), empty
    }
    private static let parseLock = NSLock()
    private static var parsed: [String: ParsedCommand] = [:]

    static func parse(_ command: String) -> Self? {
        parseLock.lock()
        let hit = parsed[command]
        parseLock.unlock()
        if let hit {
            switch hit {
            case .parsed(let value): return value
            case .empty: return nil
            }
        }
        let value: Self? = parseUncached(command)
        parseLock.lock()
        if parsed.count > 2048 { parsed.removeAll() }
        parsed[command] = value.map(ParsedCommand.parsed) ?? .empty
        parseLock.unlock()
        return value
    }

    private static func parseUncached(_ command: String) -> Self? {
        // The lightweight lexer does not parse substitutions. In `SDK=$(find
        // /path ...)` a path or option inside the substitution is not the command.
        guard !command.contains("$("), !command.contains("`") else { return nil }
        for words in segments(command) {
            var words = words
            // Compound-command syntax is not the operation: `do grep …` is grep, and
            // the `for f in …` header, `done` and `fi` describe nothing by themselves.
            while let first = words.first, Self.leadingKeywords.contains(first) { words.removeFirst() }
            if let first = words.first, Self.structuralKeywords.contains(first) { continue }
            while let first = words.first, first.contains("="), !first.hasPrefix("-") { words.removeFirst() }
            while let first = words.first, ["env", "command", "exec"].contains(first) {
                words.removeFirst()
                while let value = words.first {
                    if value == "--" { words.removeFirst(); break }
                    if ["-u", "--unset", "-C", "--chdir"].contains(value), words.count > 1 {
                        words.removeFirst(2)
                    } else if value.contains("=") || ["-i", "--ignore-environment", "-p"].contains(value) {
                        words.removeFirst()
                    } else { break }
                }
            }
            guard let first = words.first else { continue }
            let executable = (first as NSString).lastPathComponent.lowercased()
            // Incomplete wrappers/conditions must never turn a flag into a name.
            guard !executable.isEmpty, !executable.hasPrefix("-") else { return nil }
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
        if ["[", "[[", "test"].contains(executable) { return L("检查条件") }
        if executable == "git" {
            var rest = arguments
            while let first = rest.first, first.hasPrefix("-") {
                if ["-C", "-c", "--git-dir", "--work-tree"].contains(first), rest.count > 1 { rest.removeFirst(2) }
                else { rest.removeFirst() }
            }
            return ([executable] + rest.prefix(1)).joined(separator: " ")
        }
        if ["swift", "cargo", "go", "npm", "pnpm", "yarn", "bun"].contains(executable),
           let action = arguments.first, !action.hasPrefix("-") {
            return ([executable] + arguments.prefix(action == "run" ? 2 : 1)).joined(separator: " ")
        }
        return executable
    }

    /// Classify the entire command conservatively. A read followed by an unknown
    /// operation is execution, not exploration. Shell syntax stays available in
    /// full; this small display parser does not attempt to prove shell semantics.
    static func groupingPhase(_ command: String) -> ActivityNarrativePhase {
        guard !command.contains(">"), !command.contains("$("), !command.contains("`"),
              !command.contains("\n"), !command.contains("<(") else { return .mixed }
        let commands = segments(command)
        var phases: [ActivityNarrativePhase] = []
        for words in commands {
            guard let first = words.first else { continue }
            let name = (first as NSString).lastPathComponent.lowercased()
            if name == "cd" { continue }
            if ["bash", "sh", "zsh"].contains(name), words.count == 3, ["-c", "-lc"].contains(words[1]) {
                phases.append(groupingPhase(words[2])); continue
            }
            // Control flow, environment wrappers and assignments are deliberately
            // neutral here even when the compact label can identify their target.
            if leadingKeywords.contains(first) || structuralKeywords.contains(first) || first.contains("=") {
                return .mixed
            }
            let activity = Self(executable: name, arguments: Array(words.dropFirst()))
            let phase: ActivityNarrativePhase
            if ["[", "[[", "test"].contains(name) { phase = .exploring }
            else if name == "git" {
                phase = ["git status", "git diff", "git log", "git show", "git ls-files"].contains(activity.compactTarget) ? .exploring : .mixed
            } else if activity.category == "read" {
                if name == "sed" || words.contains(where: { ["-exec", "-execdir", "-delete", "-fprint", "--pre"].contains($0) || $0.hasPrefix("--pre=") }) { return .mixed }
                phase = .exploring
            } else { phase = activity.phase == .validating ? .validating : .mixed }
            phases.append(phase)
        }
        guard let first = phases.first, phases.allSatisfy({ $0 == first }) else { return .mixed }
        return first
    }

    static func segments(_ command: String) -> [[String]] {
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
