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
    private var projectLocations: [String: SidebarProjectLocation] = [:]
    public private(set) var result = Result()
    public init() {}
    public func update(_ sessions: [WorkspaceSession], query: String, locale: Locale,
                       projectLocations: [String: SidebarProjectLocation] = [:]) -> Result {
        if catalog != sessions || language != locale.identifier || self.projectLocations != projectLocations {
            catalog = sessions; language = locale.identifier
            self.projectLocations = projectLocations
            records = sessions.filter { !$0.archived }.map { item in
                let agent = item.reference.kind == .terminal ? L("终端", locale: locale) : item.reference.kind.label
                let project = projectLocations[item.id]
                return (item, "\(item.title) \(item.directory) \(item.hostName) \(item.detail) \(agent) \(project?.directory ?? "") \(project?.hostName ?? "")")
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
