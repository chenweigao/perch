import AppKit
import SwiftUI

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
let app = NSApplication.shared
let editor = DraftTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 100))
editor.isRichText = false
editor.allowsUndo = true
var draft = "已写好的草稿 "
var height: CGFloat = 40
let representable = ComposerEditor(text: Binding(get: { draft }, set: { draft = $0 }),
                                  height: Binding(get: { height }, set: { height = $0 }),
                                  placeholder: "", accessibilityLabel: "测试输入", canSend: true,
                                  onSend: {}, onFiles: nil, onError: nil, onKey: nil)
let coordinator = ComposerEditor.Coordinator(representable)
coordinator.editor = editor
editor.delegate = coordinator
editor.string = draft
editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
editor.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
check(editor.hasMarkedText(), "Fixture must enter actual AppKit marked-text state")
let composing = editor.string
for _ in 0..<100 { editor.syncDraft("已写好的草稿 ") }
check(editor.string == composing && editor.hasMarkedText(), "Stream refresh must preserve marked text and prior draft")
check(draft == "已写好的草稿 ", "Marked input must not leak into published draft")
var sends = 0
var queued = 0
editor.canSend = true
editor.onSend = { sends += 1 }
editor.onQueue = { queued += 1 }
check(!editor.handleReturn(keyCode: 36, modifiers: []), "Composition Return must remain owned by input method")
check(!editor.handleReturn(keyCode: 36, modifiers: .command), "Composition Command-Return must remain owned by input method")
check(sends == 0 && queued == 0, "Candidate confirmation must not submit")
editor.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
check(!editor.hasMarkedText() && editor.string == "已写好的草稿 中文", "Committed Chinese must replace only marked text")
check(draft == editor.string, "Delegate must publish committed Chinese before next refresh")
editor.syncDraft(draft)
check(editor.string == "已写好的草稿 中文", "Immediate SwiftUI refresh must preserve newly committed text")
check(!editor.handleReturn(keyCode: 36, modifiers: .shift), "Shift Return must allow a newline")
editor.insertNewline(nil)
check(editor.string.hasSuffix("中文\n"), "Newline must stay in the draft")
check(editor.handleReturn(keyCode: 36, modifiers: []) && sends == 1 && queued == 0, "Plain Return must submit committed draft once")
// While a turn runs, Command-Return takes the next-turn send instead of Return's, never both.
check(editor.handleReturn(keyCode: 36, modifiers: .command) && queued == 1 && sends == 1, "Command-Return must send for the next turn once")
check(editor.handleReturn(keyCode: 76, modifiers: [.command, .numericPad]) && queued == 2 && sends == 1, "Keypad Command-Enter must match Command-Return")
check(editor.handleReturn(keyCode: 36, modifiers: .control) && sends == 2 && queued == 2, "Control-Return must still send like Return")
check(!editor.handleReturn(keyCode: 36, modifiers: [.command, .shift]) && !editor.handleReturn(keyCode: 36, modifiers: [.command, .option])
      && sends == 2 && queued == 2, "Shift and Option must keep Command-Return a newline")
editor.onQueue = nil
check(editor.handleReturn(keyCode: 36, modifiers: .command) && sends == 3 && queued == 2, "Without a next-turn send Command-Return must send like Return")
editor.onQueue = { queued += 1 }
editor.canSend = false
check(editor.handleReturn(keyCode: 36, modifiers: []) && sends == 3, "Disabled submit must not call send")
check(editor.handleReturn(keyCode: 36, modifiers: .command) && sends == 3 && queued == 2, "Disabled submit must not queue either")
editor.onQueue = nil
editor.syncDraft("")
check(editor.string.isEmpty, "Confirmed successful send can clear the committed draft")
editor.syncDraft("另一段会话草稿")
check(editor.string == "另一段会话草稿", "New committed draft can replace the editing buffer")
check(editor.selectedRange() == NSRange(location: (editor.string as NSString).length, length: 0), "Completion and quotes leave the caret after the new draft")
editor.setSelectedRange(NSRange(location: 2, length: 0))
editor.syncDraft(editor.string)
check(editor.selectedRange().location == 2, "An unchanged streaming refresh must not move the caret")
editor.string = "开头 replace 结尾"
draft = editor.string
editor.setSelectedRange((editor.string as NSString).range(of: "replace"))
editor.setMarkedText("zhongjian", selectedRange: NSRange(location: 9, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
for _ in 0..<100 { editor.syncDraft(draft) }
editor.insertText("中间", replacementRange: NSRange(location: NSNotFound, length: 0))
editor.syncDraft(draft)
check(editor.string == "开头 中间 结尾" && draft == editor.string, "Middle composition must preserve both sides and publish replacement")
print("Composer checks passed: marked-text refresh, Chinese commit, Return safety, newline and draft reset")

// Use a private pasteboard so the checks never replace the user's clipboard.
let plainBoard = NSPasteboard(name: NSPasteboard.Name("dev.agentworkbench.composer-checks.\(UUID().uuidString)"))
defer { plainBoard.releaseGlobally() }
plainBoard.setString("中文输入保留测试", forType: .string)
editor.syncDraft("")
draft = ""
editor.setSelectedRange(NSRange(location: 0, length: 0))
check(editor.readSelection(from: plainBoard), "Plain Unicode pasteboard must be readable")
check(editor.string == "中文输入保留测试" && draft == editor.string, "Unicode paste must synchronously update the draft")
for _ in 0..<100 { editor.syncDraft(draft) }
check(editor.string == "中文输入保留测试", "Unicode paste must survive streaming refresh")
editor.setAccessibilityValue("通过辅助功能输入中文")
check(editor.string == "通过辅助功能输入中文" && draft == editor.string, "Accessibility input must also publish Chinese before refresh")
for _ in 0..<100 { editor.syncDraft(draft) }
check(editor.string == "通过辅助功能输入中文", "Accessibility input must survive streaming refresh")
print("Unicode private-pasteboard checks passed")

// Exercise AppKit's type negotiation, not a direct call to the attachment handler.
let imageBoard = NSPasteboard(name: NSPasteboard.Name("dev.agentworkbench.image-checks.\(UUID().uuidString)"))
defer { imageBoard.releaseGlobally() }
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.setColor(.blue, atX: 0, y: 0)
var pasted: [URL] = []
var pasteError: String?
editor.onFiles = { pasted.append(contentsOf: $0) }
editor.onError = { pasteError = $0 }
let originalDraft = editor.string
defer { for file in pasted { try? FileManager.default.removeItem(at: file) } }
for (type, format) in [(NSPasteboard.PasteboardType.png, NSBitmapImageRep.FileType.png), (.tiff, .tiff)] {
    imageBoard.clearContents()
    imageBoard.setData(bitmap.representation(using: format, properties: [:])!, forType: type)
    check(imageBoard.availableType(from: editor.readablePasteboardTypes) == type, "Image-only clipboard must enable AppKit Paste")
    let before = pasted.count
    check(editor.readSelection(from: imageBoard), "Image-only paste must reach the native read-selection path")
    check(pasted.count == before + 1 && pasteError == nil, "Exactly one attachment must be emitted")
    let image = NSBitmapImageRep(data: try Data(contentsOf: pasted.last!))!
    check(image.pixelsWide == 2 && image.pixelsHigh == 2, "Pasted PNG must retain image dimensions")
    check(editor.string == originalDraft, "Image paste must preserve existing text")
}
imageBoard.clearContents()
imageBoard.writeObjects(pasted.map { $0 as NSURL })
let originalFiles = pasted
check(editor.readSelection(from: imageBoard), "Finder file URLs must remain pasteable")
check(Array(pasted.suffix(originalFiles.count)) == originalFiles, "Multiple pasted file URLs must be delivered together")
// Non-image local files replace only the selection; images retain attachments.
let fileFolder = FileManager.default.temporaryDirectory.appendingPathComponent("perch-reference-check-\(UUID())")
try FileManager.default.createDirectory(at: fileFolder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: fileFolder) }
let textFile = fileFolder.appendingPathComponent("中文 file.txt")
try "fixture".write(to: textFile, atomically: true, encoding: .utf8)
editor.syncDraft("before replace after")
editor.setSelectedRange((editor.string as NSString).range(of: "replace"))
editor.fileReference = { url in url == textFile ? "@reference " : nil }
let imageFile = pasted[0]
let attachmentCount = pasted.count
imageBoard.clearContents()
imageBoard.writeObjects([textFile as NSURL, imageFile as NSURL])
check(editor.readSelection(from: imageBoard, type: .fileURL), "Mixed local file paste is handled")
check(editor.string == "before @reference  after", "Reference replaces the selection and preserves surrounding draft")
check(pasted.count == attachmentCount + 1 && pasted.last == imageFile, "Image stays attached while text becomes a reference")
editor.fileReference = nil
imageBoard.clearContents(); imageBoard.writeObjects([textFile as NSURL])
let remoteDraft = editor.string
check(editor.readSelection(from: imageBoard, type: .fileURL), "Remote file paste is handled")
check(pasted.last == textFile && editor.string == remoteDraft, "Remote hosts attach local files without changing draft")
print("File reference paste checks passed: mixed image/text, selection replacement, remote attachment boundary")
editor.onFiles = nil
imageBoard.clearContents()
imageBoard.setData(bitmap.representation(using: .png, properties: [:])!, forType: .png)
check(imageBoard.availableType(from: editor.readablePasteboardTypes) == nil, "Text-only connections must not advertise image support")
print("Attachment paste checks passed: native PNG/TIFF negotiation, file URLs, draft preservation and text-only capability")

var navigations = 0
editor.onKey = { _ in navigations += 1; return true }
func navigationEvent(_ flags: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: 0, context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                    isARepeat: false, keyCode: 125)!
}
check(editor.handleNavigation(navigationEvent([.numericPad, .function, .capsLock])), "Hardware arrow flags must not disable command completion")
check(!editor.handleNavigation(navigationEvent([.command, .numericPad])), "Editing shortcuts must remain owned by the text editor")
editor.isEditable = false
check(!editor.handleNavigation(navigationEvent(.numericPad)) && navigations == 1, "Disabled composer must not apply completions")
check(!editor.handleReturn(keyCode: 36, modifiers: []), "Disabled composer must not submit")
editor.onFiles = { pasted.append(contentsOf: $0) }
check(!editor.readSelection(from: imageBoard, type: .png), "Disabled composer must not accept pasted attachments")
print("Composer interaction checks passed: caret, native arrow flags and disabled input")

editor.isEditable = true
editor.syncDraft("")
editor.insertText("undo this draft", replacementRange: NSRange(location: NSNotFound, length: 0))
editor.breakUndoCoalescing()
check(editor.undoManager?.canUndo == true, "Typing must support Undo")
editor.undoManager?.undo()
check(editor.string.isEmpty, "Undo removes the last edit")
editor.undoManager?.redo()
check(editor.string == "undo this draft", "Redo restores the last edit")
editor.syncDraft("")
check(editor.undoManager?.canUndo == false, "A sent draft must not remain in this composer's undo history")
print("Composer undo checks passed: isolated typing, redo and send boundary")
editor.syncDraft("中文 file suffix", selection: NSRange(location: 7, length: 0))
check(editor.selectedRange().location == 7, "File completion must restore the insertion caret instead of jumping past the suffix")

// Long plain-text pastes fold into tokens; short pastes stay inline.
editor.syncDraft("")
editor.onLongPaste = { $0.utf8.count >= 1000 ? "@paste(\"deadbeef\")" : nil }
let longText = String(repeating: "日志行\n", count: 120)
plainBoard.clearContents()
plainBoard.setString(longText, forType: .string)
check(editor.readSelection(from: plainBoard), "Long paste must fold through the callback")
check(editor.string == "@paste(\"deadbeef\")", "Folded paste inserts the token, not the content")
check(draft == editor.string, "The folded token publishes to the draft")
editor.onLongPaste = nil
plainBoard.setString(longText, forType: .string)
check(editor.readSelection(from: plainBoard) && editor.string.hasSuffix(longText), "Without a folder the same paste stays inline")
print("Long-paste folding checks passed")

var recall = ComposerRecall()
let sent = ["第一条指令", "第二条指令"]
// One-line drafts: the caret is on the first and the last line at once.
let up = ComposerKey.up(fromFirstLine: true), down = ComposerKey.down(fromLastLine: true)
check(recall.handle(up, draft: "正在输入", entries: sent) == nil, "A non-empty draft keeps Up as cursor movement")
check(recall.handle(up, draft: "", entries: sent) == "第二条指令", "Empty draft recalls the newest prompt")
check(recall.handle(up, draft: "第二条指令", entries: sent) == "第一条指令", "Up again moves to the older prompt")
check(recall.handle(up, draft: "第一条指令", entries: sent) == "第一条指令", "The oldest entry stays selected and consumes the key")
check(recall.handle(down, draft: "第一条指令", entries: sent) == "第二条指令", "Down walks back toward the newest")
check(recall.handle(down, draft: "第二条指令", entries: sent) == "", "Down past the newest restores the empty draft")
check(!recall.isActive, "Recall ends after returning to the draft")
recall.draftChanged("第一条指令") // An edit while inactive has nothing to end.
check(recall.handle(up, draft: "", entries: sent) == "第二条指令" && recall.isActive, "Recall restarts from the newest entry")
recall.draftChanged("第二条指令") // The applied value itself must not end recall.
check(recall.isActive, "Applying a recalled draft is not an edit")
recall.draftChanged("第二条指令。")
check(!recall.isActive, "Editing the recalled draft ends recall")
check(recall.handle(.escape, draft: "第二条指令。", entries: sent) == nil, "Escape after an edit is normal editing")
check(recall.handle(up, draft: "", entries: sent) == "第二条指令", "Recall starts from the newest again")
check(recall.handle(.escape, draft: "第二条指令", entries: sent) == "" && !recall.isActive, "Escape during recall restores the empty draft")
check(recall.handle(up, draft: "", entries: []) == nil, "A session without history keeps Up as cursor movement")
print("Composer recall checks passed: empty-draft start, walk, edit and escape boundaries")

// A recalled multi-line prompt: arrows move the caret until it reaches an edge line.
let threeLines = "第一行\n第二行\n第三行"
let history = ["单行指令", threeLines]
var lineRecall = ComposerRecall()
check(lineRecall.handle(.up(fromFirstLine: false), draft: "", entries: history) == threeLines, "An empty draft recalls whatever line is reported")
check(lineRecall.handle(.up(fromFirstLine: false), draft: threeLines, entries: history) == nil && lineRecall.isActive,
      "Up below the first line moves the caret and keeps recall")
check(lineRecall.handle(.down(fromLastLine: false), draft: threeLines, entries: history) == nil && lineRecall.isActive,
      "Down above the last line moves the caret and keeps recall")
check(lineRecall.handle(.up(fromFirstLine: true), draft: threeLines, entries: history) == "单行指令", "Up on the first line recalls the older prompt")
check(lineRecall.handle(.up(fromFirstLine: true), draft: "单行指令", entries: history) == "单行指令", "The oldest prompt still consumes Up")
check(lineRecall.handle(.down(fromLastLine: true), draft: "单行指令", entries: history) == threeLines, "Down on the last line recalls the newer prompt")
check(lineRecall.handle(.down(fromLastLine: false), draft: threeLines, entries: history) == nil && lineRecall.isActive,
      "Down above the last line keeps the newest recalled prompt")
check(lineRecall.handle(.escape, draft: threeLines, entries: history) == "" && !lineRecall.isActive, "Escape still clears a multi-line recall")
check(lineRecall.handle(.up(fromFirstLine: true), draft: "正在输入", entries: history) == nil, "Typed text on its first line never starts recall")
check(lineRecall.handle(.up(fromFirstLine: true), draft: "", entries: history) == threeLines
      && lineRecall.handle(.down(fromLastLine: true), draft: threeLines, entries: history) == "" && !lineRecall.isActive,
      "Down on the last line past the newest clears the draft")

// Edge lines come from the text view's own layout, so a soft wrap counts as a line.
let lines = DraftTextView(frame: .zero)
lines.isRichText = false
lines.font = .systemFont(ofSize: 14)
lines.textContainer?.lineFragmentPadding = 0
lines.isVerticallyResizable = true
lines.textContainer?.widthTracksTextView = true
lines.textContainer?.containerSize = NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
lines.setFrameSize(NSSize(width: 240, height: 400))
func edgeName(_ line: (isFirst: Bool, isLast: Bool)) -> String {
    line.isFirst ? (line.isLast ? "both" : "first") : (line.isLast ? "last" : "neither")
}
// A closure, not a function, so the text view is used from the same context as the checks above.
let edgeLines = { (selection: NSRange, affinity: NSSelectionAffinity) -> String in
    lines.setSelectedRange(selection, affinity: affinity, stillSelecting: false)
    return edgeName(lines.caretLine())
}
func caretAt(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }
lines.syncDraft(threeLines)
check(edgeLines(caretAt(5), .downstream) == "neither", "A caret on line 2 of a 3-line draft is on neither edge line")
check(edgeLines(caretAt(1), .downstream) == "first" && edgeLines(caretAt(3), .downstream) == "first", "Line 1 is the first line up to its line break")
check(edgeLines(caretAt(9), .downstream) == "last" && edgeLines(caretAt((threeLines as NSString).length), .downstream) == "last",
      "Line 3 is the last line through its end")
check(edgeLines(NSRange(location: 1, length: 6), .downstream) == "neither", "A selection is on neither edge line")
check(lines.layoutManager != nil && lines.textLayoutManager == nil, "Edge lines use the composer's TextKit 1 layout")
var arrows: [ComposerKey] = []
lines.onKey = { arrows.append($0); return false }
func arrow(_ keyCode: UInt16) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .numericPad, timestamp: 0, windowNumber: 0, context: nil,
                     characters: keyCode == 126 ? "\u{F700}" : "\u{F701}", charactersIgnoringModifiers: keyCode == 126 ? "\u{F700}" : "\u{F701}",
                     isARepeat: false, keyCode: keyCode)!
}
lines.setSelectedRange(NSRange(location: 5, length: 0))
check(!lines.handleNavigation(arrow(126)) && !lines.handleNavigation(arrow(125)), "Unclaimed arrows stay with the text view")
lines.setSelectedRange(NSRange(location: 1, length: 0))
_ = lines.handleNavigation(arrow(126))
check(arrows == [.up(fromFirstLine: false), .down(fromLastLine: false), .up(fromFirstLine: true)], "Arrows report the caret's edge line")
lines.onKey = nil
let paragraph = String(repeating: "一段会自动换行的长文字，", count: 8)
lines.syncDraft(paragraph)
var firstFragment = NSRange(location: 0, length: 0)
_ = lines.layoutManager!.lineFragmentRect(forGlyphAt: 0, effectiveRange: &firstFragment)
let wrap = lines.layoutManager!.characterIndexForGlyph(at: NSMaxRange(firstFragment))
check(wrap > 0 && wrap < (paragraph as NSString).length, "The fixture paragraph must wrap")
check(edgeLines(caretAt(0), .downstream) == "first" && edgeLines(caretAt((paragraph as NSString).length), .downstream) == "last",
      "A wrapped paragraph has separate first and last lines")
check(edgeLines(caretAt((paragraph as NSString).length / 2), .downstream) == "neither", "The middle of a wrapped paragraph is on neither edge line")
check(edgeLines(caretAt(wrap), .upstream) == "first", "Upstream at a soft wrap the caret ends the first line")
check(edgeLines(caretAt(wrap), .downstream) != "first", "Downstream at a soft wrap the caret starts the next line")
lines.syncDraft("结尾换行\n")
check(edgeLines(caretAt(5), .downstream) == "last" && edgeLines(caretAt(4), .downstream) == "first",
      "After a final line break the caret is on the empty last line")
lines.syncDraft("")
check(edgeLines(caretAt(0), .downstream) == "both", "An empty draft is on both edge lines")
print("Composer edge-line checks passed: hard and soft line breaks, selection, affinity and arrow payloads")
if let path = ProcessInfo.processInfo.environment["COMPOSER_CHECK_RESULT"] {
    try Data("{\"status\":\"passed\"}\n".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
}
