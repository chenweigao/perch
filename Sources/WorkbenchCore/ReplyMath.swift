import Foundation

/// TeX math extraction for reply Markdown (ccgui remark-math parity, native
/// renderer). Display math is an atomic block — the reveal cursor treats it as
/// a wholesale checkpoint, never a per-character reveal.
public enum ReplyMath {
    private struct Fence {
        let character: Character
        let length: Int
    }

    private struct FenceMarker {
        let character: Character
        let length: Int
        let closesFence: Bool
    }

    /// Normalize backslash delimiters before swift-markdown can consume their
    /// backslashes. Code spans and fenced blocks retain their original source.
    static func normalizeDelimiters(_ source: String) -> String {
        guard source.contains("\\") else { return source }
        var result = ""
        result.reserveCapacity(source.count)
        var index = source.startIndex
        var atLineStart = true
        var fence: Fence?

        while index < source.endIndex {
            if atLineStart {
                let marker = fenceMarker(in: source, at: index)
                if fence != nil || marker != nil {
                    let lineEnd = source[index...].firstIndex(of: "\n").map { source.index(after: $0) } ?? source.endIndex
                    if let active = fence {
                        if let marker, marker.character == active.character,
                           marker.length >= active.length, marker.closesFence {
                            fence = nil
                        }
                    } else if let marker {
                        fence = Fence(character: marker.character, length: marker.length)
                    }
                    result.append(contentsOf: source[index..<lineEnd])
                    index = lineEnd
                    continue
                }
            }

            if source[index] == "\n" {
                result.append("\n")
                index = source.index(after: index)
                atLineStart = true
                continue
            }

            if source[index] == "`", !isEscaped(source, at: index) {
                let runEnd = backtickRunEnd(source, at: index)
                let length = source.distance(from: index, to: runEnd)
                if let spanEnd = codeSpanEnd(source, from: runEnd, delimiterLength: length) {
                    result.append(contentsOf: source[index..<spanEnd])
                    index = spanEnd
                } else {
                    result.append(contentsOf: source[index..<runEnd])
                    index = runEnd
                }
                atLineStart = false
                continue
            }

            if source[index] == "\\" {
                let runEnd = backslashRunEnd(source, at: index)
                let count = source.distance(from: index, to: runEnd)
                if count % 2 == 1, runEnd < source.endIndex,
                   source[runEnd] == "(" || source[runEnd] == "[",
                   let close = closingDelimiter(source, from: source.index(after: runEnd),
                                                character: source[runEnd] == "(" ? ")" : "]") {
                    let contentStart = source.index(after: runEnd)
                    let content = source[contentStart..<close.lowerBound]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty {
                        let openingSlash = source.index(before: runEnd)
                        result.append(contentsOf: source[index..<openingSlash])
                        let delimiter = source[runEnd] == "[" ? "$$" : "$"
                        result.append(delimiter)
                        result.append(content.replacingOccurrences(of: "\\", with: "\\\\"))
                        result.append(delimiter)
                        index = close.upperBound
                        atLineStart = false
                        continue
                    }
                }
                result.append(contentsOf: source[index..<runEnd])
                index = runEnd
                atLineStart = false
                continue
            }

            result.append(source[index])
            index = source.index(after: index)
            atLineStart = false
        }
        return result
    }

    private static func closingDelimiter(_ source: String, from start: String.Index,
                                         character: Character) -> Range<String.Index>? {
        var index = start
        while index < source.endIndex, let slash = source[index...].firstIndex(of: "\\") {
            let runEnd = backslashRunEnd(source, at: slash)
            let count = source.distance(from: slash, to: runEnd)
            if count % 2 == 1, runEnd < source.endIndex, source[runEnd] == character {
                return source.index(before: runEnd)..<source.index(after: runEnd)
            }
            index = runEnd
        }
        return nil
    }

    private static func codeSpanEnd(_ source: String, from start: String.Index,
                                    delimiterLength: Int) -> String.Index? {
        var index = start
        while index < source.endIndex, let tick = source[index...].firstIndex(of: "`") {
            let runEnd = backtickRunEnd(source, at: tick)
            if source.distance(from: tick, to: runEnd) == delimiterLength { return runEnd }
            index = runEnd
        }
        return nil
    }

    private static func backtickRunEnd(_ source: String, at start: String.Index) -> String.Index {
        var index = start
        while index < source.endIndex, source[index] == "`" { index = source.index(after: index) }
        return index
    }

    private static func backslashRunEnd(_ source: String, at start: String.Index) -> String.Index {
        var index = start
        while index < source.endIndex, source[index] == "\\" { index = source.index(after: index) }
        return index
    }

    private static func isEscaped(_ source: String, at index: String.Index) -> Bool {
        var cursor = index
        var count = 0
        while cursor > source.startIndex {
            let previous = source.index(before: cursor)
            guard source[previous] == "\\" else { break }
            count += 1
            cursor = previous
        }
        return count % 2 == 1
    }

    private static func fenceMarker(in source: String, at start: String.Index) -> FenceMarker? {
        var index = start
        var spaces = 0
        while index < source.endIndex, source[index] == " ", spaces < 4 {
            spaces += 1
            index = source.index(after: index)
        }
        guard spaces <= 3, index < source.endIndex,
              source[index] == "`" || source[index] == "~" else { return nil }
        let character = source[index]
        var runEnd = index
        while runEnd < source.endIndex, source[runEnd] == character {
            runEnd = source.index(after: runEnd)
        }
        let length = source.distance(from: index, to: runEnd)
        guard length >= 3 else { return nil }
        var trailing = runEnd
        while trailing < source.endIndex, source[trailing] == " " || source[trailing] == "\t" {
            trailing = source.index(after: trailing)
        }
        let closesFence = trailing == source.endIndex || source[trailing] == "\n"
        return FenceMarker(character: character, length: length, closesFence: closesFence)
    }

    /// Extract an outer `\boxed{...}` so the native renderer can draw the border
    /// itself; SwiftMath 1.7.3 does not recognize this command.
    public static func boxedContent(_ latex: String) -> String? {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = #"\boxed{"#
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix("}") else { return nil }
        let contentStart = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
        let finalBrace = trimmed.index(before: trimmed.endIndex)
        var depth = 1
        var index = contentStart
        while index < trimmed.endIndex {
            if trimmed[index] == "\\" {
                index = trimmed.index(after: index)
                if index < trimmed.endIndex { index = trimmed.index(after: index) }
                continue
            }
            if trimmed[index] == "{" { depth += 1 }
            if trimmed[index] == "}" {
                depth -= 1
                if depth == 0 {
                    guard index == finalBrace else { return nil }
                    let content = String(trimmed[contentStart..<index])
                    return content.isEmpty ? nil : content
                }
            }
            index = trimmed.index(after: index)
        }
        return nil
    }

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
