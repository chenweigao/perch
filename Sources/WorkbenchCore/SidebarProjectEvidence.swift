import Foundation

/// Navigation evidence comes from actual tool inputs, never prose, titles or
/// command output. Strings are inspected only; no recorded command is executed.
public enum SidebarProjectEvidence {
    public static func directories(messages: [KimiMessage], cwd: String, limit: Int = 32) -> [String] {
        var paths: [String] = []
        func absolute(_ value: String, base: String) -> String? {
            guard !value.isEmpty, !value.contains("\0"),
                  !value.contains("$"), !value.contains("`"), !value.hasPrefix("~") else { return nil }
            let path = value.hasPrefix("/") ? value : base + "/" + value
            guard path.hasPrefix("/") else { return nil }
            return (path as NSString).standardizingPath
        }
        // Recent operations win equal scores. Keep repetitions across calls so a
        // one-off reference cannot outweigh sustained work on another repository.
        for part in messages.reversed().flatMap({ $0.content.reversed() }) where part.type == "tool_use" {
            guard let input = part.input else { continue }
            var call: [String] = []
            let base = ["cwd", "workdir", "working_directory"].compactMap { input[$0].string }
                .first.flatMap { absolute($0, base: cwd) } ?? cwd
            if base != cwd { call.append(base) }
            for key in ["path", "file_path", "filename"] {
                if let raw = input[key].string, let path = absolute(raw, base: base) {
                    call.append(path)
                    call.append((path as NSString).deletingLastPathComponent)
                }
            }
            if let command = input["command"].string ?? input["cmd"].string {
                // A heredoc body is program text, not shell navigation evidence.
                let shell = command.components(separatedBy: "<<")[0]
                var directory = base
                for words in ShellActivity.segments(shell) {
                    if words.first == "cd", let operand = words.dropFirst().first(where: { $0 != "--" }),
                       let path = absolute(operand, base: directory) {
                        directory = path; call.append(path)
                    } else if words.first.map({ ($0 as NSString).lastPathComponent }) == "git",
                              let index = words.firstIndex(of: "-C"), words.indices.contains(index + 1),
                              let path = absolute(words[index + 1], base: directory) { call.append(path) }
                }
            }
            var seen = Set<String>()
            paths += call.filter { seen.insert($0).inserted }
        }
        var included = Set<String>()
        return paths.filter { path in
            if included.contains(path) { return true }
            guard included.count < limit else { return false }
            included.insert(path); return true
        }
    }

    public static func project(directories: [String], matches: [String: SidebarRepositoryMatch]) -> String? {
        var scores: [String: Int] = [:], order: [String] = []
        for directory in directories {
            guard let match = matches[directory], match.isRepository else { continue }
            if scores[match.directory] == nil { order.append(match.directory) }
            scores[match.directory, default: 0] += 1
        }
        return order.max { scores[$0, default: 0] < scores[$1, default: 0] }
    }
}
