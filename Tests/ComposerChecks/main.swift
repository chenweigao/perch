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
editor.canSend = true
editor.onSend = { sends += 1 }
check(!editor.handleReturn(keyCode: 36, modifiers: []), "Composition Return must remain owned by input method")
check(sends == 0, "Candidate confirmation must not submit")
editor.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
check(!editor.hasMarkedText() && editor.string == "已写好的草稿 中文", "Committed Chinese must replace only marked text")
check(draft == editor.string, "Delegate must publish committed Chinese before next refresh")
editor.syncDraft(draft)
check(editor.string == "已写好的草稿 中文", "Immediate SwiftUI refresh must preserve newly committed text")
check(!editor.handleReturn(keyCode: 36, modifiers: .shift), "Shift Return must allow a newline")
editor.insertNewline(nil)
check(editor.string.hasSuffix("中文\n"), "Newline must stay in the draft")
check(editor.handleReturn(keyCode: 36, modifiers: []) && sends == 1, "Plain Return must submit committed draft once")
editor.canSend = false
check(editor.handleReturn(keyCode: 36, modifiers: []) && sends == 1, "Disabled submit must not call send")
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
if let path = ProcessInfo.processInfo.environment["COMPOSER_CHECK_RESULT"] {
    try Data("{\"status\":\"passed\"}\n".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
}
