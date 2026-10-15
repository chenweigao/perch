import AppKit
import WorkbenchCore

/// Stands in for a transcript row: one entry whose text views share a selection.
@MainActor private final class ReplySelectionFixture: NSView, ReplySelectionScope {
    override var isFlipped: Bool { true }
    var replySource: String?
}

/// A drag from a native reply's heading into its last list item selects across
/// the reply's separate text views; copy reads the whole span; a click elsewhere
/// ends it; ⌘A selects the whole reply; the context menu copies it as plain text.
@MainActor func checkCrossViewSelection() async throws {
    AppLanguage.applyToSystem(.zhHans)
    let source = "## 标题甲\n\n第一段正文。\n\n- 列表项一\n- 列表项二"
    guard let blocks = NativeAssistantContent.make(source) else { throw WorkbenchError("Native reply rejected the fixture") }
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 720, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    defer { window.orderOut(nil) }
    let scope = ReplySelectionFixture(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
    scope.replySource = source
    let reply = NativeAssistantMessageView.acquire()
    defer { NativeAssistantMessageView.recycle(reply) }
    reply.update(blocks, source: source, dark: false)
    reply.frame = NSRect(origin: NSPoint(x: 40, y: 20), size: reply.measure(width: 640))
    reply.place(width: 640)
    scope.addSubview(reply)
    window.contentView = scope
    window.orderFront(nil)
    for _ in 0..<3 {
        try await Task.sleep(for: .milliseconds(50))
        scope.layoutSubtreeIfNeeded(); scope.displayIfNeeded()
    }

    let views = ReplySelection.textViews(in: scope)
    guard views.map(\.string) == ["标题甲", "第一段正文。", "列表项一", "列表项二"] else {
        throw WorkbenchError("Expected four text views in reading order, got \(views.map(\.string))")
    }
    let heading = views[0], last = views[3]
    func mouse(_ type: NSEvent.EventType, _ point: NSPoint, clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clickCount,
                           pressure: type == .leftMouseUp ? 0 : 1)!
    }
    func point(in view: NSTextView, character: Int, trailing: Bool) -> NSPoint {
        let rect = view.firstRect(forCharacterRange: NSRange(location: character, length: 1), actualRange: nil)
        return window.convertPoint(fromScreen: NSPoint(x: trailing ? rect.maxX + 12 : rect.minX + 1, y: rect.midY))
    }
    let start = point(in: heading, character: 0, trailing: false)
    let end = point(in: last, character: (last.string as NSString).length - 1, trailing: true)
    let middle = NSPoint(x: end.x, y: (start.y + end.y) / 2)
    // NSTextView's drag loop reads the queued drag and release events.
    for step in [middle, end] { NSApp.postEvent(mouse(.leftMouseDragged, step), atStart: false) }
    NSApp.postEvent(mouse(.leftMouseUp, end), atStart: false)
    heading.mouseDown(with: mouse(.leftMouseDown, start))

    let whole = "标题甲\n第一段正文。\n列表项一\n列表项二"
    guard heading.selectedRange() == NSRange(location: 0, length: 3) else {
        throw WorkbenchError("The heading kept \(heading.selectedRange()) instead of running to its end")
    }
    guard ReplySelection.shared.text(from: heading) == whole else {
        throw WorkbenchError("The drag selected \(String(describing: ReplySelection.shared.text(from: heading)))")
    }
    for view in views.dropFirst() {
        guard view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil else {
            throw WorkbenchError("\(view.string) shows no selection highlight")
        }
    }
    NSPasteboard.general.clearContents()
    heading.copy(nil)
    guard NSPasteboard.general.string(forType: .string) == whole else { throw WorkbenchError("Copy did not include the whole span") }

    // A click in another view ends the span and leaves no selection behind.
    NSApp.postEvent(mouse(.leftMouseUp, end), atStart: false)
    last.mouseDown(with: mouse(.leftMouseDown, end))
    guard views.allSatisfy({ $0.selectedRange().length == 0 }), ReplySelection.shared.text(from: heading) == nil,
          views.allSatisfy({ $0.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil }) else {
        throw WorkbenchError("A click elsewhere left part of the previous selection")
    }

    // ⌘A in any paragraph selects the whole reply.
    views[1].selectAll(nil)
    guard ReplySelection.shared.text(from: views[1]) == whole else { throw WorkbenchError("Select All stayed within one paragraph") }

    // The context menu copies the reply without Markdown syntax.
    let menu = views[2].menu(for: mouse(.rightMouseDown, end))
    guard let item = menu?.items.first(where: { $0.title == L("复制整条回复（纯文本）") }),
          item.representedObject as? String == ReplyPlainText.text(from: source) else {
        throw WorkbenchError("The reply context menu has no plain-text copy")
    }
    print("PASS: cross-view reply selection — drag across heading, paragraph and list items, copy, click clears, Select All, plain-text menu")
}
