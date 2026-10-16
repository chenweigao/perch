import Foundation

/// Project-level slash commands read from the session's working directory, using
/// the conventions Claude Code (`.claude/commands/*.md`) and opencode
/// (`.opencode/command/*.md`) already established: the file name becomes the
/// command, the Markdown body becomes the prompt template. Choosing one expands
/// the template into the composer draft instead of sending a command name —
/// the runtimes only know their own commands.
public enum ProjectCommandCatalog {
    public static let maxFilesPerDirectory = 32
    public static let maxBytesPerFile = 20_000
    public static let directories = [".claude/commands", ".opencode/commands", ".opencode/command"]

    /// One sh script for local and remote reads. Each command file becomes a
    /// `>>name` record followed by one base64 line, so arbitrary Markdown
    /// survives the trip unescaped. Missing directories are silently skipped.
    public static func script(cwd: String) -> String {
        var script = ""
        for directory in directories {
            let quoted = SSHCommand.quote(cwd + "/" + directory)
            script += """
            if [ -d \(quoted) ]; then
              n=0
              for f in \(quoted)/*.md; do
                [ -f "$f" ] || continue
                n=$((n+1)); [ "$n" -gt \(maxFilesPerDirectory) ] && break
                name=$(basename "$f" .md)
                case "$name" in *[!A-Za-z0-9_-]*) continue ;; esac
                printf '>>%s\\n' "$name"
                head -c \(maxBytesPerFile) "$f" | base64 | tr -d '[:space:]'
                printf '\\n'
              done
            fi

            """
        }
        return script
    }

    public static func parse(_ data: Data) -> [AgentCommand] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var commands: [AgentCommand] = []
        var seen: Set<String> = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.hasPrefix(">>") else { index += 1; continue }
            let name = String(line.dropFirst(2))
            let payloadIndex = index + 1
            index += 2
            guard !seen.contains(name), payloadIndex < lines.count,
                  let body = Data(base64Encoded: String(lines[payloadIndex]))
                .flatMap({ String(data: $0, encoding: .utf8) }) else { continue }
            seen.insert(name)
            let stripped = stripFrontmatter(body)
            let prompt = stripped.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { continue }
            commands.append(AgentCommand(name: name, description: stripped.description, source: "project", prompt: prompt))
        }
        return commands.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The composer draft for a chosen project command. `$ARGUMENTS` receives the
    /// text after the command name (Claude Code's convention); templates without
    /// the placeholder take the arguments as a trailing paragraph.
    public static func expand(_ command: AgentCommand, arguments: String) -> String {
        guard let prompt = command.prompt else { return "" }
        if prompt.contains("$ARGUMENTS") {
            return prompt.replacingOccurrences(of: "$ARGUMENTS", with: arguments)
        }
        return arguments.isEmpty ? prompt : prompt + "\n\n" + arguments
    }

    /// An optional `---` frontmatter block carries the palette description; it is
    /// not part of the prompt. Without one, the first content line describes.
    static func stripFrontmatter(_ body: String) -> (description: String?, body: String) {
        var rest = body
        var description: String?
        if rest.hasPrefix("---\n") || rest.hasPrefix("---\r\n") {
            let lines = rest.components(separatedBy: .newlines)
            if let close = lines.dropFirst().firstIndex(where: { $0 == "---" }) {
                for line in lines[1..<close] {
                    if line.hasPrefix("description:") {
                        let value = line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
                        if !value.isEmpty { description = value }
                    }
                }
                rest = lines[(close + 1)...].joined(separator: "\n")
            }
        }
        if description == nil {
            description = rest.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
                .map { String($0.trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces).prefix(80)) }
        }
        return (description, rest)
    }
}
