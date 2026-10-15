import Foundation
import WorkbenchCore

/// Plain-text copy keeps what a reader sees; a drag across text views selects the
/// anchor's side, whole views in between and the focus view up to the pointer.
func checkReplySelection() {
    let source = """
    ## 结论

    先看 **重点** 和 `code`，再读 [文档](https://example.com/doc)。

    1. 第一项
    2. 第二项
       - 嵌套项

    > 引用里的话

    ```swift
    let x = 1
    ```

    | 列 | 值 |
    | --- | --- |
    | a | 1 |
    """
    let text = ReplyPlainText.text(from: source)
    let expected = """
    结论

    先看 重点 和 code，再读 文档 (https://example.com/doc)。

    1. 第一项
    2. 第二项
       • 嵌套项

    > 引用里的话

    let x = 1

    列\t值
    a\t1
    """
    precondition(text == expected, "plain text:\n\(text)")
    precondition(!text.contains("**") && !text.contains("```") && !text.contains("|"))

    let lengths = [10, 20, 30, 40]
    typealias Point = TextSelectionSpan.Point
    // Within one view the range runs between the two offsets in either direction.
    precondition(TextSelectionSpan.ranges(anchor: Point(view: 1, offset: 12), focus: Point(view: 1, offset: 4), lengths: lengths)
                 == [1: NSRange(location: 4, length: 8)])
    // Dragging down: the anchor's tail, whole views in between, the focus view's head.
    precondition(TextSelectionSpan.ranges(anchor: Point(view: 0, offset: 6), focus: Point(view: 3, offset: 5), lengths: lengths)
                 == [0: NSRange(location: 6, length: 4), 1: NSRange(location: 0, length: 20),
                     2: NSRange(location: 0, length: 30), 3: NSRange(location: 0, length: 5)])
    // Dragging up: the anchor's head and the focus view's tail.
    precondition(TextSelectionSpan.ranges(anchor: Point(view: 2, offset: 7), focus: Point(view: 1, offset: 15), lengths: lengths)
                 == [2: NSRange(location: 0, length: 7), 1: NSRange(location: 15, length: 5)])
    // Offsets past either end clamp; unknown views select nothing.
    precondition(TextSelectionSpan.ranges(anchor: Point(view: 0, offset: 99), focus: Point(view: 1, offset: -3), lengths: lengths)
                 == [0: NSRange(location: 10, length: 0), 1: NSRange(location: 0, length: 0)])
    precondition(TextSelectionSpan.ranges(anchor: Point(view: 0, offset: 0), focus: Point(view: 9, offset: 0), lengths: lengths).isEmpty)
    print("PASS: reply plain text, cross-view selection spans")
}
