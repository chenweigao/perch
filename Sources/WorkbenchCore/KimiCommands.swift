import Foundation

/// Commands backed by Kimi's REST endpoints, not its TUI-only command registry.
public enum KimiCommand: Equatable {
    case compact(String), goalStatus, goalStart(String), goalControl(String), plan(Bool), help

    public static var catalog: [AgentCommand] { [
        AgentCommand(name: "goal", description: L("Start or manage a goal"),
                     subcommands: ["status", "pause", "resume", "cancel"].map { AgentCommand(name: $0) },
                     input: .init(hint: "[objective | status | pause | resume | cancel]")),
        AgentCommand(name: "compact", description: L("Compact conversation context"), input: .init(hint: "[instructions]")),
        AgentCommand(name: "plan", description: L("Change plan mode"), subcommands: [AgentCommand(name: "on"), AgentCommand(name: "off")]),
        AgentCommand(name: "help", description: L("Show available commands"))
    ] }

    public static func parse(_ draft: String) throws -> KimiCommand? {
        guard let invocation = SlashCommands.invocation(in: draft, from: catalog) else { return nil }
        let args = invocation.arguments
        switch invocation.command.name {
        case "compact": return .compact(args)
        case "help":
            guard args.isEmpty else { throw WorkbenchError(L("Usage: /help")) }
            return .help
        case "plan":
            guard ["on", "off"].contains(args) else { throw WorkbenchError(L("Usage: /plan on or /plan off")) }
            return .plan(args == "on")
        default:
            if args.isEmpty || args == "status" { return .goalStatus }
            if ["pause", "resume", "cancel"].contains(args) { return .goalControl(args) }
            let first = args.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            if ["status", "pause", "resume", "cancel", "replace", "next"].contains(first) {
                throw WorkbenchError(L("Use /goal status, pause, resume, cancel, or /goal -- followed by an objective. Replace and next are not available here."))
            }
            let objective = first == "--" ? String(args.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines) : args
            guard !objective.isEmpty else { throw WorkbenchError(L("Enter an objective after /goal.")) }
            return .goalStart(objective)
        }
    }

    public var requiresIdle: Bool {
        switch self {
        case .compact, .goalStart, .goalControl("resume"), .plan: return true
        default: return false
        }
    }
    public static var helpText: String {
        "/goal <objective>\n/goal status | pause | resume | cancel\n/compact [instructions]\n/plan on | off\n/help"
    }
}

public struct KimiGoal: Decodable {
    public let objective: String
    public let status: String
    public let turnsUsed: Int
    public let tokensUsed: Int
}
