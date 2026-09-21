import SwiftUI
import WorkbenchCore

/// Keys the composer hands to an attached palette before acting on them itself.
/// Kept minimal so the composer stays a text editor rather than a menu host.
enum ComposerKey { case up, down, enter, tab, escape }

/// Suggestions for a slash draft, rendered above the composer. Entirely driven by
/// the command list the runtime reported, so a session with no commands shows
/// nothing rather than a hard-coded menu.
struct CommandPalette: View {
    let completion: CommandCompletion
    let selection: Int
    let onChoose: (AgentCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let parent = completion.parent {
                Text("/\(parent.name) 的子命令").font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 3)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(completion.matches.enumerated()), id: \.element.id) { index, command in
                            CommandPaletteRow(command: command, selected: index == selection) { onChoose(command) }
                                .id(command.id)
                        }
                    }.padding(.horizontal, 6).padding(.vertical, 6)
                }.frame(maxHeight: 220)
                    .onChange(of: selection) { _, value in
                        guard completion.matches.indices.contains(value) else { return }
                        proxy.scrollTo(completion.matches[value].id, anchor: .bottom)
                    }
            }
            Divider()
            Text("↑↓ 选择 · Return 补全 · Esc 关闭。补全只填入输入框，不会立即执行。")
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(10)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            .accessibilityLabel("命令建议，\(completion.matches.count) 项")
    }
}

private struct CommandPaletteRow: View {
    let command: AgentCommand
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("/\(command.name)").font(.system(size: 12, design: .monospaced)).lineLimit(1)
                if let description = command.description {
                    Text(description).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                // The hint tells the user arguments are expected before they commit.
                if let hint = command.hint {
                    Text(hint).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                } else if !command.children.isEmpty {
                    Text("\(command.children.count) 个子命令").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }.padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
                .background(selected || hovered ? Color.primary.opacity(0.06) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Palette state for one composer: which row is highlighted, and whether the user
/// dismissed the suggestions for the text they are currently typing.
struct CommandPaletteState {
    private(set) var selection = 0
    private var dismissedDraft: String?

    func completion(for draft: String, in commands: [AgentCommand]?) -> CommandCompletion? {
        guard draft != dismissedDraft, let commands else { return nil }
        guard let value = SlashCommands.completion(for: draft, in: commands), !value.isEmpty else { return nil }
        return value
    }
    /// Editing after a dismissal brings the suggestions back, and any change resets
    /// the highlight so Return cannot apply a row the user can no longer see.
    mutating func draftChanged(_ draft: String) {
        if let dismissed = dismissedDraft, draft != dismissed { dismissedDraft = nil }
        selection = 0
    }
    mutating func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }
    mutating func dismiss(_ draft: String) { dismissedDraft = draft; selection = 0 }
    func choice(in completion: CommandCompletion) -> AgentCommand? {
        completion.matches.indices.contains(selection) ? completion.matches[selection] : completion.matches.first
    }
}
