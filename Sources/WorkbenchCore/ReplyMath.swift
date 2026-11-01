import Foundation

/// TeX math extraction for reply Markdown (ccgui remark-math parity, native
/// renderer). Display math is an atomic block — the reveal cursor treats it as
/// a wholesale checkpoint, never a per-character reveal.
public enum ReplyMath {
    private struct Fence {
        let character: UInt8
        let length: Int
    }

    private struct FenceMarker {
        let character: UInt8
        let length: Int
        let closesFence: Bool
    }

    private struct Boundaries {
        var math: [Int: Range<Int>] = [:]
        var code: [Int: Int] = [:]

        init(_ bytes: [UInt8]) {
            var markers: [(start: Int, slash: Int, character: UInt8)] = []
            var ticks: [Range<Int>] = []
            var index = 0
            while index < bytes.count {
                let character = bytes[index]
                if character == 92 || character == 96 {
                    let start = index
                    repeat { index += 1 } while index < bytes.count && bytes[index] == character
                    if character == 96 {
                        ticks.append(start..<index)
                    } else if (index - start) % 2 == 1, index < bytes.count,
                              [40, 41, 91, 93].contains(bytes[index]) {
                        markers.append((start, index - 1, bytes[index]))
                    }
                } else {
                    index += 1
                }
            }
            var closers: [UInt8: Range<Int>] = [:]
            for marker in markers.reversed() {
                if marker.character == 41 || marker.character == 93 {
                    closers[marker.character] = marker.slash..<(marker.slash + 2)
                } else if let close = closers[marker.character == 40 ? 41 : 93] {
                    math[marker.start] = close
                }
            }
            var nextTick: [Int: Int] = [:]
            for tick in ticks.reversed() {
                if let end = nextTick[tick.count] { code[tick.lowerBound] = end }
                nextTick[tick.count] = tick.upperBound
            }
        }
    }

    /// Resolve boundaries in bounded passes, including unmatched streaming input.
    /// The original source remains unchanged outside paired math delimiters.
    static func normalizeDelimiters(_ source: String) -> String {
        guard source.contains(#"\("#) || source.contains(#"\["#) else { return source }
        let bytes = Array(source.utf8)
        let boundaries = Boundaries(bytes)
        var result: [UInt8] = []
        var copyFrom = 0
        var index = 0
        var atLineStart = true
        var fence: Fence?

        while index < bytes.count {
            if atLineStart {
                let marker = fenceMarker(in: bytes, at: index)
                if fence != nil || marker != nil {
                    if let active = fence {
                        if let marker, marker.character == active.character,
                           marker.length >= active.length, marker.closesFence {
                            fence = nil
                        }
                    } else if let marker {
                        fence = Fence(character: marker.character, length: marker.length)
                    }
                    while index < bytes.count, bytes[index] != 10 { index += 1 }
                    if index < bytes.count { index += 1 }
                    continue
                }
            }
            if bytes[index] == 10 {
                index += 1
                atLineStart = true
                continue
            }
            if bytes[index] == 96, !isEscaped(bytes, at: index) {
                if let end = boundaries.code[index] {
                    index = end
                } else {
                    repeat { index += 1 } while index < bytes.count && bytes[index] == 96
                }
                atLineStart = false
                continue
            }
            if bytes[index] == 92 {
                let start = index
                repeat { index += 1 } while index < bytes.count && bytes[index] == 92
                if (index - start) % 2 == 1, let close = boundaries.math[start] {
                    let content = String(decoding: bytes[(index + 1)..<close.lowerBound], as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty {
                        if result.isEmpty { result.reserveCapacity(bytes.count) }
                        result.append(contentsOf: bytes[copyFrom..<(index - 1)])
                        let display = bytes[index] == 91
                        result.append(36)
                        if display { result.append(36) }
                        for byte in content.utf8 {
                            result.append(byte)
                            if byte == 92 { result.append(byte) }
                        }
                        result.append(36)
                        if display { result.append(36) }
                        index = close.upperBound
                        copyFrom = index
                    }
                }
                atLineStart = false
                continue
            }
            index += 1
            atLineStart = false
        }
        guard copyFrom > 0 else { return source }
        result.append(contentsOf: bytes[copyFrom...])
        return String(decoding: result, as: UTF8.self)
    }

    private static func isEscaped(_ bytes: [UInt8], at index: Int) -> Bool {
        var start = index
        while start > 0, bytes[start - 1] == 92 { start -= 1 }
        return (index - start) % 2 == 1
    }

    private static func fenceMarker(in bytes: [UInt8], at start: Int) -> FenceMarker? {
        var index = start
        while index < bytes.count, bytes[index] == 32, index - start < 4 { index += 1 }
        guard index - start <= 3, index < bytes.count,
              bytes[index] == 96 || bytes[index] == 126 else { return nil }
        let character = bytes[index]
        var runEnd = index
        while runEnd < bytes.count, bytes[runEnd] == character { runEnd += 1 }
        guard runEnd - index >= 3 else { return nil }
        var trailing = runEnd
        while trailing < bytes.count, bytes[trailing] == 32 || bytes[trailing] == 9 { trailing += 1 }
        return FenceMarker(character: character, length: runEnd - index,
                           closesFence: trailing == bytes.count || bytes[trailing] == 10)
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
