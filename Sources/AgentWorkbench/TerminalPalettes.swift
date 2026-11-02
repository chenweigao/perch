import AppKit
import GhosttyTerminal

/// One shared terminal look for full-pane and floating shells.
/// Dark shares the window's blue-graphite canvas (WorkbenchTheme's
/// contentBackground, #1F2229) so the terminal reads as part of the
/// content surface instead of a neutral-gray insert; ANSI hues are the
/// light palette's, lifted for the darker ground.
enum TerminalPalettes {
    static let light = TerminalConfiguration()
        .background("ffffff").foreground("272b36")
        .selectionBackground("dce5fa").selectionForeground("202535")
        .cursorColor("6062c9").cursorText("ffffff")
        .palette(0, color: "343943").palette(1, color: "bc4050")
        .palette(2, color: "26785d").palette(3, color: "967018")
        .palette(4, color: "3767bc").palette(5, color: "8155a1")
        .palette(6, color: "207d8a").palette(7, color: "b6bbc7")
        .palette(8, color: "747b8c").palette(9, color: "ca4f5e")
        .palette(10, color: "308767").palette(11, color: "a97e23")
        .palette(12, color: "4b78cf").palette(13, color: "9267b1")
        .palette(14, color: "2d8a96").palette(15, color: "e1e4ed")
    static let dark = TerminalConfiguration()
        .background("1f2229").foreground("d8dae1")
        .selectionBackground("323c52").selectionForeground("e8eaf0")
        .cursorColor("7a7ce0").cursorText("1f2229")
        .palette(0, color: "454c59").palette(1, color: "d96372")
        .palette(2, color: "4cae8c").palette(3, color: "cfa04a")
        .palette(4, color: "6f97dd").palette(5, color: "a884c4")
        .palette(6, color: "4aa8b5").palette(7, color: "c9cdd8")
        .palette(8, color: "7d8493").palette(9, color: "e07a88")
        .palette(10, color: "5cbd9c").palette(11, color: "dcb05e")
        .palette(12, color: "82a5e4").palette(13, color: "b794d1")
        .palette(14, color: "5cb5c1").palette(15, color: "eef0f5")

    static let theme = TerminalTheme(light: light, dark: dark)

    @MainActor static func makeViewState() -> TerminalViewState {
        TerminalViewState(theme: theme,
            terminalConfiguration: TerminalConfiguration().fontFamily("Menlo").fontSize(14)
                .windowPaddingX(14).windowPaddingY(12)
                .custom("clipboard-read", "deny").custom("clipboard-write", "allow")
                .custom("shell-integration", "none"))
    }
}

/// User-initiated clipboard actions belong to the native responder chain.
/// Reading remote OSC 52 requests remains denied by the terminal configuration.
/// ⌘J bubbles up so the workbench can toggle the command-line island while a
/// shell has focus.
final class WorkbenchTerminalView: AppTerminalView {
    var onInput: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        onInput?()
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        onInput?()
        super.insertText(string, replacementRange: replacementRange)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v":
                if let text = NSPasteboard.general.string(forType: .string) { onInput?(); _ = paste(text: text) }
                return true
            case "c": return copySelectedTextToPasteboard()
            case "k", "t", "n", "w", "r", "j": return false
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
