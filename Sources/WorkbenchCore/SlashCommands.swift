import Foundation

/// A command the runtime reported for this session. The list varies with the
/// extensions and plugins a session loaded, so nothing here is hard-coded.
public struct AgentCommand: Decodable, Identifiable, Equatable, Sendable {
    public struct Input: Decodable, Equatable, Sendable {
        public let hint: String?
        public init(hint: String) { self.hint = hint }
    }
    public let name: String
    public let description: String?
    public let aliases: [String]?
    public let subcommands: [AgentCommand]?
    public let input: Input?
    public let source: String?
    public var id: String { name }
    public var hint: String? { input?.hint }
    public var children: [AgentCommand] { subcommands ?? [] }

    public init(name: String, description: String? = nil, aliases: [String]? = nil,
                subcommands: [AgentCommand]? = nil, input: Input? = nil, source: String? = nil) {
        self.name = name; self.description = description; self.aliases = aliases
        self.subcommands = subcommands; self.input = input; self.source = source
    }

    func matches(_ filter: String) -> Bool {
        guard !filter.isEmpty else { return true }
        let names = [name] + (aliases ?? [])
        return names.contains { $0.lowercased().hasPrefix(filter.lowercased()) }
    }
}

public struct CommandCompletion: Equatable, Sendable {
    public let matches: [AgentCommand]
    /// Set while completing a subcommand, so applying a choice keeps the parent.
    public let parent: AgentCommand?
    public let filter: String
    public var isEmpty: Bool { matches.isEmpty }
}

public enum SlashCommands {
    /// The palette opens only for a draft that is entirely one slash command.
    /// A message that merely mentions a slash later in a sentence is ordinary text.
    public static func completion(for draft: String, in commands: [AgentCommand]) -> CommandCompletion? {
        guard draft.hasPrefix("/"), !draft.contains("\n"), !commands.isEmpty else { return nil }
        let body = draft.dropFirst()
        guard let space = body.firstIndex(of: " ") else {
            let filter = String(body)
            return CommandCompletion(matches: commands.filter { $0.matches(filter) }, parent: nil, filter: filter)
        }
        let head = String(body[body.startIndex..<space])
        let rest = String(body[body.index(after: space)...])
        // Past the first argument the user is writing input, not picking a command.
        guard !rest.contains(" "),
              let parent = commands.first(where: { $0.name == head || ($0.aliases ?? []).contains(head) }),
              !parent.children.isEmpty else { return nil }
        return CommandCompletion(matches: parent.children.filter { $0.matches(rest) }, parent: parent, filter: rest)
    }

    /// The draft after picking a suggestion. The trailing space lets the user keep
    /// typing arguments, and re-opens subcommand completion for a parent command.
    public static func draft(applying command: AgentCommand, to completion: CommandCompletion) -> String {
        guard let parent = completion.parent else { return "/\(command.name) " }
        return "/\(parent.name) \(command.name) "
    }

    /// The command a draft would run, or nil when it is ordinary text. Used to keep
    /// a slash message from being sent to the model as a literal prompt.
    public static func invocation(in draft: String, from commands: [AgentCommand]) -> (command: AgentCommand, arguments: String)? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let head = String(body.prefix { !$0.isWhitespace })
        guard let command = commands.first(where: { $0.name == head || ($0.aliases ?? []).contains(head) }) else { return nil }
        let arguments = String(body.dropFirst(head.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (command, arguments)
    }
}
