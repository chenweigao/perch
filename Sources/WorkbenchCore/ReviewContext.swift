import Foundation
import CryptoKit

/// A reference to exactly what the reader selected, not a claim about later file contents.
public struct ReviewContext: Equatable, Sendable, Identifiable {
    public var id: String { fingerprint + reference }
    public let path: String
    public let scope: String
    public let fingerprint: String
    public let lines: ClosedRange<Int>?
    public let oldLines: ClosedRange<Int>?
    public let excerpt: String

    public init(path: String, text: String, selection: NSRange, diff: Bool = false, scope: String = "file") {
        self.path = path; self.scope = scope
        fingerprint = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let ns = text as NSString
        let location = min(max(0, selection.location), ns.length)
        let length = min(max(0, selection.length), ns.length - location)
        let selected = NSRange(location: location, length: length)
        var newNumbers: [Int] = [], oldNumbers: [Int] = [], snippets: [String] = []
        var old = 0, new = 0, offset = 0, inHunk = false
        let hunk = try! NSRegularExpression(pattern: "^@@ -(\\d+)(?:,\\d+)? \\+(\\d+)(?:,\\d+)? @@")
        for (index, substring) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(substring), count = (line as NSString).length
            let intersects = length > 0 && NSIntersectionRange(selected, NSRange(location: offset, length: count + 1)).length > 0
            offset += count + 1
            if !diff {
                if intersects { newNumbers.append(index + 1); snippets.append(line) }
                continue
            }
            if let match = hunk.firstMatch(in: line, range: NSRange(location: 0, length: count)) {
                old = Int((line as NSString).substring(with: match.range(at: 1)))!
                new = Int((line as NSString).substring(with: match.range(at: 2)))!
                inHunk = true
            } else if line.hasPrefix("diff ") { inHunk = false }
            else if inHunk {
                if line.hasPrefix("+") {
                    if intersects { newNumbers.append(new) }; new += 1
                } else if line.hasPrefix("-") {
                    if intersects { oldNumbers.append(old) }; old += 1
                } else if line.hasPrefix(" ") {
                    if intersects { oldNumbers.append(old); newNumbers.append(new) }; old += 1; new += 1
                }
            }
            if intersects { snippets.append(line) }
        }
        lines = newNumbers.first.flatMap { first in newNumbers.last.map { first...$0 } }
        oldLines = oldNumbers.first.flatMap { first in oldNumbers.last.map { first...$0 } }
        excerpt = snippets.joined(separator: "\n")
    }

    public static func sourceSelection(in source: String, rendered: String, selection: NSRange) -> NSRange {
        let ns = rendered as NSString
        guard selection.length > 0, selection.location < ns.length else { return NSRange(location: 0, length: 0) }
        let end = min(NSMaxRange(selection), ns.length)
        let first = ns.substring(to: selection.location).filter { $0 == "\n" }.count + 1
        let last = ns.substring(to: end - 1).filter { $0 == "\n" }.count + 1
        guard let startRange = RemoteFileContent.lineRange(in: source, line: first),
              let endRange = RemoteFileContent.lineRange(in: source, line: last) else { return NSRange(location: 0, length: 0) }
        return NSUnionRange(startRange, endRange)
    }

    public var reference: String {
        var value = path
        if let lines { value += ":\(lines.lowerBound)-\(lines.upperBound)" }
        if let oldLines { value += " (old \(oldLines.lowerBound)-\(oldLines.upperBound))" }
        return value
    }
    public func prompt(feedback: String = "") -> String {
        let content = "\(reference)\nScope: \(scope)\nSnapshot SHA-256: \(fingerprint)\n\(excerpt)"
        let quoted = content.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        return quoted + (feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n" + feedback)
    }
}
