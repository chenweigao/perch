import Foundation

/// TeX math extraction for reply Markdown (ccgui remark-math parity, native
/// renderer). Display math is an atomic block — the reveal cursor treats it as
/// a wholesale checkpoint, never a per-character reveal.
///
/// Only `$…$` / `$$…$$` forms are detected: swift-markdown unescapes `\(` and
/// `\[`, so the backslash forms never reach the parsed text.
public enum ReplyMath {
    /// A paragraph whose entire trimmed text is a `$$…$$` display formula
    /// renders as a math block.
    public static func displayContent(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count > 4 else { return nil }
        return String(trimmed.dropFirst(2).dropLast(2))
    }

    /// Split text runs on inline `$…$` spans. Currency stays text: an opening
    /// `$` needs a non-space after it, a closing `$` a non-space before it,
    /// and no digit right after the closer (Pandoc's rule).
    public static func splitInline(_ runs: [ReplyInline]) -> [ReplyInline] {
        runs.flatMap { run -> [ReplyInline] in
            guard run.link == nil, !run.code, run.math == nil, run.text.contains("$") else { return [run] }
            return split(run)
        }
    }

    private static func split(_ run: ReplyInline) -> [ReplyInline] {
        let text = run.text
        var result: [ReplyInline] = []
        var segmentStart = text.startIndex
        var index = text.startIndex
        func flushText(upTo end: String.Index) {
            guard segmentStart < end else { return }
            var part = run
            part.text = String(text[segmentStart..<end])
            result.append(part)
        }
        while index < text.endIndex {
            guard text[index] == "$" else { index = text.index(after: index); continue }
            let openEnd = text.index(after: index)
            guard openEnd < text.endIndex, !text[openEnd].isWhitespace else { index = openEnd; continue }
            guard let closeStart = text[openEnd...].firstIndex(of: "$") else { break }
            let beforeCloser = text.index(before: closeStart)
            if text[beforeCloser].isWhitespace { index = openEnd; continue }
            let afterCloser = text.index(after: closeStart)
            if afterCloser < text.endIndex, text[afterCloser].isNumber { index = openEnd; continue }
            flushText(upTo: index)
            var math = run
            math.text = "\u{FFFC}"   // object replacement: one cursor unit
            math.math = String(text[openEnd..<closeStart])
            result.append(math)
            index = afterCloser
            segmentStart = index
        }
        flushText(upTo: text.endIndex)
        return result
    }
}
