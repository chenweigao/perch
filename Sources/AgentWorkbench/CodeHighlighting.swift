import AppKit
import JavaScriptCore

/// Token offsets always refer to the original UTF-16 source. Colors are applied
/// only while drawing, so highlighting cannot change glyph layout or selection.
struct CodeToken: Sendable {
    let range: NSRange
    let kind: Kind?
    enum Kind: String, Sendable {
        case keyword, string, comment, number, type, title, variable, meta
        var color: NSColor { Self.colors[self]! }
        // Keep readable code-specific contrast in both appearances. Only ink
        // changes; the native reader's background and font metrics stay intact.
        private static let colors: [Kind: NSColor] = {
            let values: [(Kind, UInt32, UInt32)] = [
                (.keyword, 0x9B2393, 0xFC5FA3), (.string, 0xC41A16, 0xFC6A5D),
                (.comment, 0x5D6C79, 0x8C93A1), (.number, 0x1C00CF, 0xD0BF69),
                (.type, 0x0B756F, 0x6BDFFF), (.title, 0x326D74, 0x67B7A4),
                (.variable, 0x6C36A9, 0xB281EB), (.meta, 0x643820, 0xFD8F3F)
            ]
            return Dictionary(uniqueKeysWithValues: values.map { kind, light, dark in
                (kind, NSColor(name: nil) { appearance in
                    let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                    return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                                   green: CGFloat((rgb >> 8) & 255) / 255,
                                   blue: CGFloat(rgb & 255) / 255, alpha: 1)
                })
            })
        }()
        init?(classes: String) {
            let name = classes.split(separator: " ").first.map(String.init) ?? ""
            switch name {
            case "hljs-keyword", "hljs-literal", "hljs-selector-tag": self = .keyword
            case "hljs-string", "hljs-regexp", "hljs-symbol", "hljs-bullet": self = .string
            case "hljs-comment", "hljs-quote", "hljs-doctag": self = .comment
            case "hljs-number": self = .number
            case "hljs-type", "hljs-built_in": self = .type
            case "hljs-title", "hljs-section", "hljs-attr", "hljs-name": self = .title
            case "hljs-variable", "hljs-template-variable", "hljs-attribute": self = .variable
            case "hljs-meta": self = .meta
            default: return nil
            }
        }
    }
}

enum CodeLanguage {
    static func file(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "makefile" { return "makefile" }
        return canonical((name as NSString).pathExtension)
    }
    static func canonical(_ language: String) -> String {
        let value = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let aliases = ["py": "python", "pyi": "python", "js": "javascript", "jsx": "javascript",
                       "ts": "typescript", "tsx": "typescript", "sh": "bash", "zsh": "bash",
                       "h": "c", "hpp": "cpp", "cc": "cpp", "rs": "rust", "yml": "yaml",
                       "html": "xml", "htm": "xml", "svg": "xml", "md": "markdown",
                       "m": "objectivec", "mm": "objectivec", "kt": "kotlin", "cs": "csharp",
                       "rb": "ruby", "pl": "perl", "toml": "ini"]
        return aliases[value] ?? value
    }
}

/// One JavaScriptCore VM, isolated from UI work. The bundled, pinned engine runs
/// trusted grammar code; file contents are arguments to highlight(), never eval.
actor CodeHighlighter {
    static let shared = CodeHighlighter()
    // A large JavaScript parse is synchronous. Give it a separate VM/actor so
    // switching to a small file or a conversation card never queues behind it.
    static let largeFiles = CodeHighlighter(byteLimit: 32 * 1_048_576, entryLimit: 2)
    static func engine(for source: String) -> CodeHighlighter {
        source.utf8.count > 256 * 1024 ? largeFiles : shared
    }
    private let byteLimit: Int
    private let entryLimit: Int
    init(byteLimit: Int = 8 * 1_048_576, entryLimit: Int = 24) {
        self.byteLimit = byteLimit; self.entryLimit = entryLimit
    }
    private var context: JSContext?
    private struct Key: Hashable { let source: String; let language: String }
    private var cache: [Key: [CodeToken]] = [:]
    private var order: [Key] = []
    private(set) var cacheBytes = 0
    private(set) var parseCount = 0
    enum Failure: Error { case missingEngine, invalidOutput }

    func highlight(_ source: String, language: String) throws -> [CodeToken] {
        try Task.checkCancellation()
        guard !source.isEmpty, !language.isEmpty else { return [] }
        let key = Key(source: source, language: language)
        if let hit = cache[key] {
            order.removeAll { $0 == key }; order.append(key)
            return hit
        }
        if context == nil {
            guard let url = Bundle.main.url(forResource: "highlight.min", withExtension: "js"),
                  let vm = JSContext() else { throw Failure.missingEngine }
            vm.evaluateScript(try String(contentsOf: url, encoding: .utf8))
            guard vm.exception == nil else { throw Failure.invalidOutput }
            context = vm
        }
        let engine = context!.objectForKeyedSubscript("hljs")!
        guard engine.invokeMethod("getLanguage", withArguments: [language])?.isUndefined == false else { return [] }
        parseCount += 1
        guard let html = engine.invokeMethod("highlight", withArguments: [source, ["language": language, "ignoreIllegals": true]])?.forProperty("value")?.toString(),
              context!.exception == nil else { throw Failure.invalidOutput }
        try Task.checkCancellation()
        let decoder = HighlightTokens()
        // XML normalizes literal CR/CRLF; character references preserve offsets.
        let xml = "<code>" + html.replacingOccurrences(of: "\r", with: "&#13;") + "</code>"
        let parser = XMLParser(data: Data(xml.utf8)); parser.delegate = decoder
        let parsed = parser.parse()
        try Task.checkCancellation()
        guard parsed, decoder.text == source else { throw Failure.invalidOutput }
        let tokens = decoder.tokens
        let cost = source.utf16.count * 2 + tokens.count * MemoryLayout<CodeToken>.stride
        // Cache immutable token data for remounted conversation cards, never views.
        if cost <= byteLimit {
            while !order.isEmpty && (order.count >= entryLimit || cacheBytes + cost > byteLimit) {
                let oldest = order.removeFirst()
                if let removed = cache.removeValue(forKey: oldest) {
                    cacheBytes -= oldest.source.utf16.count * 2 + removed.count * MemoryLayout<CodeToken>.stride
                }
            }
            cache[key] = tokens; order.append(key); cacheBytes += cost
        }
        return tokens
    }
}

private final class HighlightTokens: NSObject, XMLParserDelegate {
    var tokens: [CodeToken] = []
    var text = ""
    private var offset = 0
    private var scopes: [CodeToken.Kind?] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        scopes.append(attributes["class"].flatMap(CodeToken.Kind.init(classes:)) ?? scopes.last.flatMap { $0 })
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { scopes.removeLast() }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if Task.isCancelled { parser.abortParsing(); return }
        let length = string.utf16.count, kind = scopes.last.flatMap { $0 }
        if let last = tokens.last, last.kind == kind {
            tokens[tokens.count - 1] = CodeToken(range: NSRange(location: last.range.location, length: last.range.length + length), kind: kind)
        } else { tokens.append(CodeToken(range: NSRange(location: offset, length: length), kind: kind)) }
        offset += length; text += string
    }
}

/// Also supplies file-search colors at draw time. Moving to another match only
/// changes selection; no full-text attribute mutation or repeated search occurs.
@MainActor final class CodeHighlightController: NSObject, @MainActor NSLayoutManagerDelegate {
    private weak var view: NSTextView?
    private var task: Task<Void, Never>?
    private var source = "", language = ""
    private(set) var tokens: [CodeToken] = []
    var matches: [NSRange] = [] { didSet { view?.needsDisplay = true } }
    private(set) var ready = false
    private(set) var error: Error?
    init(view: NSTextView) { self.view = view; super.init(); view.layoutManager?.delegate = self }
    deinit { task?.cancel() }
    func update(source: String, language: String, debounce: Bool = false) {
        let language = CodeLanguage.canonical(language)
        guard self.source != source || self.language != language else { return }
        task?.cancel(); self.source = source; self.language = language
        tokens = []; ready = false; error = nil
        view?.needsDisplay = true
        guard !language.isEmpty, !source.isEmpty else { ready = true; return }
        task = Task { [weak self] in
            do {
                if debounce { try await Task.sleep(for: .milliseconds(150)) }
                let tokens = try await CodeHighlighter.engine(for: source).highlight(source, language: language)
                try Task.checkCancellation()
                guard let self, self.source == source, self.language == language else { return }
                self.tokens = tokens; self.ready = true; self.view?.needsDisplay = true
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, let self, self.source == source, self.language == language else { return }
                self.error = error; self.ready = true
            }
        }
    }
    func reset() {
        task?.cancel(); task = nil; source = ""; language = ""; tokens = []; matches = []; ready = false; error = nil
    }
    func layoutManager(_ layoutManager: NSLayoutManager, shouldUseTemporaryAttributes attrs: [NSAttributedString.Key: Any], forDrawingToScreen toScreen: Bool, atCharacterIndex index: Int, effectiveRange: NSRangePointer?) -> [NSAttributedString.Key: Any]? {
        var result = attrs
        if let token = tokens.firstEnding(after: index, range: { $0.range }), NSLocationInRange(index, token.range) {
            if let color = token.kind?.color { result[.foregroundColor] = color }
            if let effectiveRange { effectiveRange.pointee = NSIntersectionRange(effectiveRange.pointee, token.range) }
        }
        if let match = matches.firstEnding(after: index, range: { $0 }), let effectiveRange {
            let range = index < match.location ? NSRange(location: index, length: match.location - index) : match
            effectiveRange.pointee = NSIntersectionRange(effectiveRange.pointee, range)
            if NSLocationInRange(index, match) { result[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.25) }
        }
        return result
    }
}

private extension Array {
    func firstEnding(after index: Int, range: (Element) -> NSRange) -> Element? {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(range(self[mid])) <= index { low = mid + 1 } else { high = mid }
        }
        return low < count ? self[low] : nil
    }
}

enum SourceSearch {
    /// Swift 5 async nonisolated work runs on the cooperative executor, not UI.
    static func matches(in text: String, query: String) async throws -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let source = text as NSString
        var result: [NSRange] = [], start = 0
        while start < source.length {
            if result.count % 128 == 0 { try Task.checkCancellation() }
            let match = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: start, length: source.length - start))
            if match.location == NSNotFound || match.length == 0 { break }
            result.append(match); start = NSMaxRange(match)
        }
        return result
    }
}

@MainActor final class FileSearchController {
    private weak var view: NSTextView?
    private let highlighting: CodeHighlightController
    private var task: Task<Void, Never>?
    private var text: String?, query = "", index = 0
    private(set) var searchCount = 0
    private(set) var searching = false
    init(view: NSTextView, highlighting: CodeHighlightController) { self.view = view; self.highlighting = highlighting }
    deinit { task?.cancel() }
    func cancel() { task?.cancel(); task = nil }
    func update(text: String, query: String, index: Int) {
        let changed = self.text != text || self.query != query
        let moved = self.index != index
        self.index = index
        guard changed else { if moved { reveal() }; return }
        cancel(); self.text = text; self.query = query
        highlighting.matches = []; searching = !query.isEmpty
        guard !query.isEmpty else { return }
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                self?.searchCount += 1
                let matches = try await SourceSearch.matches(in: text, query: query)
                try Task.checkCancellation()
                guard let self, self.text == text, self.query == query else { return }
                self.highlighting.matches = matches; self.searching = false; self.reveal()
            } catch { }
        }
    }
    private func reveal() {
        let matches = highlighting.matches
        guard let view, !matches.isEmpty else { return }
        let range = matches[((index % matches.count) + matches.count) % matches.count]
        view.setSelectedRange(range); view.scrollRangeToVisible(range)
    }
}
