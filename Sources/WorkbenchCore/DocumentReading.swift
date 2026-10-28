import Foundation
import Markdown

/// Document-relative paths are resolved on the document's host, never on this Mac.
public enum DocumentLink {
    public enum Destination: Equatable { case file(String, anchor: String?), web(URL), blocked }
    public static func url(_ target: String) -> URL? {
        var parts = URLComponents(); parts.scheme = "perch-document"; parts.host = "link"
        parts.queryItems = [URLQueryItem(name: "target", value: target)]
        return parts.url
    }
    public static func target(_ url: URL) -> String? {
        guard url.scheme == "perch-document" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "target" }?.value
    }
    public static func resolve(_ target: String, relativeTo path: String) -> Destination {
        guard !target.contains("\0"), !target.hasPrefix("//"),
              let parts = URLComponents(string: target) else { return .blocked }
        if let scheme = parts.scheme {
            if ["https", "http", "mailto"].contains(scheme.lowercased()), let url = parts.url { return .web(url) }
            return .blocked
        }
        guard parts.query == nil, let parent = RemoteFilePath.parent(of: path) else { return .blocked }
        let resolved = parts.path.isEmpty ? path : (try? RemoteFilePath.resolve(parts.path, cwd: parent))
        guard let resolved else { return .blocked }
        return .file(resolved, anchor: parts.fragment)
    }
}

public struct DocumentSection: Identifiable, Sendable {
    public let id: Int
    public let blocks: [ReplyBlock]
    public let text: String
    public let heading: String?
    public let level: Int
    public let anchor: String?
    public let chapter: String
    public let line: Int
    public let images: [DocumentImage]
}
public struct DocumentImage: Identifiable, Equatable, Sendable {
    public let target: String
    public let alt: String
    public var id: String { target }
}

/// Immutable parser output; only visible blocks acquire native text views.
public struct ReadingDocument: Sendable {
    public let sections: [DocumentSection]
    public var outline: [DocumentSection] { sections.filter { $0.heading != nil } }
    public init(_ source: String) {
        var sections: [DocumentSection] = [], slugs: Set<String> = []
        var chapter = ""
        for (index, node) in Document(parsing: source).children.enumerated() {
            let blocks = ReplyDocument.blocks(from: node, documentLinks: true)
            var title: String?, anchor: String?
            var level = 0
            if case .heading(let depth, let runs) = blocks.first {
                title = runs.map(\.text).joined(); chapter = title!; level = depth
                let base = Self.slug(chapter)
                var candidate = base, suffix = 0
                while slugs.contains(candidate) { suffix += 1; candidate = base + "-\(suffix)" }
                slugs.insert(candidate); anchor = candidate
            }
            var images: [DocumentImage] = []
            func collect(_ node: Markup) {
                if let image = node as? Markdown.Image, let target = image.source,
                   !images.contains(where: { $0.target == target }) {
                    images.append(DocumentImage(target: target, alt: image.plainText))
                }
                for child in node.children { collect(child) }
            }
            collect(node)
            sections.append(DocumentSection(id: index, blocks: blocks, text: ReplyPlainText.render(blocks),
                heading: title, level: level, anchor: anchor, chapter: chapter,
                line: node.range?.lowerBound.line ?? 1, images: images))
        }
        self.sections = sections
    }
    public func matchingSections(_ query: String) -> [Int] {
        guard !query.isEmpty else { return [] }
        return sections.filter { $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.map(\.id)
    }
    public static func slug(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) || $0 == "-" || $0 == "_"
        }).replacingOccurrences(of: " ", with: "-")
    }
}

public struct ProjectDocument: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public let project: SidebarProjectLocation
    public let path: String
    public var title: String
    public var source: SessionReference?
    public var pinned = false
    public var lastReadAt: Double
    public var modifiedAt: Double?
    public init(project: SidebarProjectLocation, path: String, title: String, source: SessionReference?,
                now: Date = Date(), modifiedAt: Double? = nil) {
        self.project = project; self.path = path; self.title = title; self.source = source
        lastReadAt = now.timeIntervalSince1970; self.modifiedAt = modifiedAt
    }
}

/// Serial CPU work off the UI actor. Cancelled queued pages do no parsing; a
/// synchronous parse already in progress finishes, then discards its result.
public actor DocumentParser {
    public static let shared = DocumentParser()
    public func parse(_ source: String) -> ReadingDocument? {
        guard !Task.isCancelled else { return nil }
        let document = ReadingDocument(source)
        return Task.isCancelled ? nil : document
    }
}
