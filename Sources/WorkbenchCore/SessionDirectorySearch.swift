import Foundation

public final class SessionDirectorySearch {
    public struct Result {
        public var sessions: [WorkspaceSession] = []
        public var online: [WorkspaceSession] = []
    }
    private var catalog: [WorkspaceSession] = []
    private var language = ""
    private var records: [(WorkspaceSession, String)] = []
    private var query: String?
    public private(set) var result = Result()
    public init() {}
    public func update(_ sessions: [WorkspaceSession], query: String, locale: Locale) -> Result {
        if catalog != sessions || language != locale.identifier {
            catalog = sessions; language = locale.identifier
            records = sessions.filter { !$0.archived }.map { item in
                let agent = item.reference.kind == .terminal ? L("终端", locale: locale) : item.reference.kind.label
                return (item, "\(item.title) \(item.directory) \(item.hostName) \(item.detail) \(agent)")
            }
            self.query = nil
        }
        if self.query != query {
            let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
            result.sessions = records.compactMap { item, text in
                terms.allSatisfy { text.localizedStandardContains($0) } ? item : nil
            }
            result.online = result.sessions.filter(\.online)
            self.query = query
        }
        return result
    }
}
