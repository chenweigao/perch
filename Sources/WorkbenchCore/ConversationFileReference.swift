import Foundation

public struct ConversationFileReference: Equatable {
    public let path: String
    public let line: Int?
    public init?(text: String) {
        guard !text.contains("://"), !text.contains("\n"), !text.hasPrefix("mailto:") else { return nil }
        let pattern = #"^(.+?)(?::([1-9][0-9]*)(?::[0-9]+)?|#L([1-9][0-9]*))?$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let source = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) else { return nil }
        let path = source.substring(with: match.range(at: 1))
        guard !path.contains(":"), path.contains("/") || path.contains("."), !path.hasPrefix("#") else { return nil }
        self.path = path
        let range = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
        line = range.location == NSNotFound ? nil : Int(source.substring(with: range))
    }
    public var url: URL {
        var value = URLComponents(); value.scheme = "perch-file"
        value.queryItems = [URLQueryItem(name: "path", value: path)] + (line.map { [URLQueryItem(name: "line", value: String($0))] } ?? [])
        return value.url!
    }
    public init?(url: URL) {
        guard url.scheme == "perch-file", let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let path = values.first(where: { $0.name == "path" })?.value else { return nil }
        self.path = path; line = values.first(where: { $0.name == "line" })?.value.flatMap(Int.init)
    }
    public static func matches(in text: String) -> [(NSRange, Self)] {
        let pattern = #"(?<![\w:/])(?:\.?\.?/|/)?(?:[\w.@+-]+/)*[\w@+-]+\.[A-Za-z0-9_]+(?::[1-9][0-9]*(?::[0-9]+)?|#L[1-9][0-9]*)"#
        let source = text as NSString
        return try! NSRegularExpression(pattern: pattern).matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap {
            guard let value = Self(text: source.substring(with: $0.range)) else { return nil }
            return ($0.range, value)
        }
    }
}
