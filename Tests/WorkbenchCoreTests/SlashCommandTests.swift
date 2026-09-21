import Foundation
import WorkbenchCore

func checkSlashCommands() throws {
    // Shape observed from the runtime's available_commands_update event.
    let commands = try KimiWire.decoder().decode([AgentCommand].self, from: Data("""
    [{"name":"compact","description":"Compact the conversation",
      "input":{"hint":"[soft|remote|snapcompact] [focus]"},
      "subcommands":[{"name":"soft","description":"Summarize locally with the active model"},
                     {"name":"remote","description":"Summarize via the remote endpoint"},
                     {"name":"snapcompact","description":"Snapshot then compact"}],
      "source":"builtin"},
     {"name":"model","aliases":["models"],"description":"Show current model selection","source":"builtin"},
     {"name":"context","description":"Show context usage","source":"builtin"},
     {"name":"commit-commands:commit","description":"Write a commit","source":"plugin"}]
    """.utf8))
    precondition(commands.count == 4)
    precondition(commands[0].hint == "[soft|remote|snapcompact] [focus]")
    precondition(commands[0].children.map(\.name) == ["soft", "remote", "snapcompact"])
    precondition(commands[1].aliases == ["models"])
    precondition(commands[2].children.isEmpty)

    // The palette opens only for a draft that is entirely one command.
    precondition(SlashCommands.completion(for: "", in: commands) == nil)
    precondition(SlashCommands.completion(for: "帮我看看 /compact", in: commands) == nil)
    precondition(SlashCommands.completion(for: "/compact\n继续", in: commands) == nil)
    // A runtime that announced nothing offers no palette.
    precondition(SlashCommands.completion(for: "/co", in: []) == nil)

    // A bare slash lists everything; typing filters by prefix.
    guard let all = SlashCommands.completion(for: "/", in: commands) else { fatalError("palette") }
    precondition(all.matches.count == 4 && all.parent == nil)
    guard let filtered = SlashCommands.completion(for: "/co", in: commands) else { fatalError("palette") }
    // Plugin commands are namespaced but still match on the plain prefix.
    precondition(filtered.matches.map(\.name) == ["compact", "context", "commit-commands:commit"])
    // Aliases match, and the filter is case-insensitive.
    precondition(SlashCommands.completion(for: "/models", in: commands)?.matches.map(\.name) == ["model"])
    precondition(SlashCommands.completion(for: "/COM", in: commands)?.matches.count == 2)
    // An unknown command shows no suggestions rather than a stale list.
    precondition(SlashCommands.completion(for: "/nope", in: commands)?.isEmpty == true)

    // After a command with subcommands, completion continues into its children.
    guard let sub = SlashCommands.completion(for: "/compact ", in: commands) else { fatalError("subcommands") }
    precondition(sub.parent?.name == "compact" && sub.matches.count == 3)
    precondition(SlashCommands.completion(for: "/compact s", in: commands)?.matches.map(\.name) == ["soft", "snapcompact"])
    // A command without subcommands takes free text, so the palette closes.
    precondition(SlashCommands.completion(for: "/context ", in: commands) == nil)
    // Past the first argument the user is writing input, not picking a command.
    precondition(SlashCommands.completion(for: "/compact soft 认证模块", in: commands) == nil)

    // Applying a suggestion leaves a trailing space so arguments can follow.
    precondition(SlashCommands.draft(applying: commands[0], to: all) == "/compact ")
    precondition(SlashCommands.draft(applying: sub.matches[0], to: sub) == "/compact soft ")

    // A slash draft resolves to a command instead of being sent as a prompt.
    guard let plain = SlashCommands.invocation(in: "/compact", from: commands) else { fatalError("invocation") }
    precondition(plain.command.name == "compact" && plain.arguments.isEmpty)
    guard let withArgs = SlashCommands.invocation(in: "  /compact soft 认证模块  ", from: commands) else { fatalError("invocation") }
    precondition(withArgs.command.name == "compact" && withArgs.arguments == "soft 认证模块")
    // An alias resolves to the command it belongs to.
    precondition(SlashCommands.invocation(in: "/models", from: commands)?.command.name == "model")
    // Ordinary text, unknown commands and multi-line drafts stay prompts.
    precondition(SlashCommands.invocation(in: "compact the code", from: commands) == nil)
    precondition(SlashCommands.invocation(in: "/unknown thing", from: commands) == nil)
    precondition(SlashCommands.invocation(in: "/compact\nand more", from: commands) == nil)
    print("PASS: runtime command parsing, palette open rules, subcommand completion, alias resolution and slash invocation")
}
