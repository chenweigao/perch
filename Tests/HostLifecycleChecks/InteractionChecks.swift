import AppKit
import Observation
import SwiftUI
import WorkbenchCore

@MainActor @Observable private final class DisclosureFixtureState {
    var expanded = true
    var reduced = false
}
private struct DisclosureFixture: View {
    let state: DisclosureFixtureState
    var body: some View {
        VStack(spacing: 0) {
            WorkbenchDisclosureContent(expanded: state.expanded) {
                Color.blue.frame(width: 200, height: 120)
            }
            Color.red.frame(width: 200, height: 10)
        }.frame(width: 200).environment(\.conversationReduceMotion, state.reduced)
    }
}
@MainActor private func interactionSettle(_ ms: Int = 300) async {
    try? await Task.sleep(for: .milliseconds(ms))
}
@MainActor private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
}

@MainActor func checkDisclosureAndQuestionInteractions() async throws {
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Perch Interaction Checks"
    defer { window.orderOut(nil) }
    let state = DisclosureFixtureState()
    let disclosure = NSHostingView(rootView: DisclosureFixture(state: state))
    window.contentView = disclosure
    window.makeKeyAndOrderFront(nil)
    await interactionSettle()
    precondition(disclosure.fittingSize.height == 130)
    state.expanded = false
    await interactionSettle(50)
    state.expanded = true
    await interactionSettle(500)
    precondition(disclosure.fittingSize.height == 130, "Obsolete collapse must not unmount reopened content")
    state.expanded = false
    await interactionSettle(500)
    precondition(disclosure.fittingSize.height == 10)
    state.expanded = true
    await interactionSettle(500)
    precondition(disclosure.fittingSize.height == 130)
    state.reduced = true; state.expanded = false
    await interactionSettle(100)
    precondition(disclosure.fittingSize.height == 10)
    state.expanded = true
    await interactionSettle(100)
    precondition(disclosure.fittingSize.height == 130)
    let question = try KimiWire.decoder().decode(KimiQuestion.self, from: Data(#"{"question_id":"q","questions":[{"id":"free","question":"Write a complete answer","options":[],"allow_other":true}]}"#.utf8))
    let connection = KimiConnection(setupHost: SSHHost(name: "Offline fixture", destination: "fixture.invalid"))
    let host = NSHostingView(rootView: KimiQuestionView(question: question, connection: connection))
    window.contentView = host
    await interactionSettle()
    func fields() -> [NSTextField] { descendants(host).compactMap { $0 as? NSTextField }.filter(\.isEditable) }
    precondition(fields().count == 1)
    window.makeFirstResponder(fields()[0])
    guard let editor = fields()[0].currentEditor() as? NSTextView else { fatalError("Missing native field editor") }
    editor.insertText("a", replacementRange: editor.selectedRange())
    await interactionSettle()
    precondition(fields().count == 1, "The first character must not collapse a free answer")
    editor.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: editor.selectedRange())
    await interactionSettle()
    precondition(fields().count == 1 && editor.hasMarkedText(), "Composition remains editable")
    editor.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
    await interactionSettle()
    precondition(fields().count == 1 && fields()[0].stringValue == "a中文")
    print("PASS: rapid disclosure reopen, closed/open restoration, reduced motion, full free answer and marked text")
}
