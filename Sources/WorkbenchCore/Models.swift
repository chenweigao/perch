import Foundation

public struct SSHHost: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var destination: String
    public var enabledAgents: [SessionKind]
    public var kimiPort: Int
    public var kimiTokenPath: String

    public init(id: UUID = UUID(), name: String, destination: String,
                enabledAgents: [SessionKind] = [.kimi, .omp, .qoder, .dsh, .codex, .terminal],
                kimiPort: Int = 58627, kimiTokenPath: String = "~/.kimi-code/server.token") {
        self.id = id; self.name = name; self.destination = destination
        self.enabledAgents = enabledAgents; self.kimiPort = kimiPort; self.kimiTokenPath = kimiTokenPath
    }
    enum CodingKeys: String, CodingKey { case id, name, destination, enabledAgents, kimiPort, kimiTokenPath }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        destination = try c.decode(String.self, forKey: .destination)
        // Existing saved hosts retain their previous connections until reconfigured.
        enabledAgents = try c.decodeIfPresent([SessionKind].self, forKey: .enabledAgents) ?? [.kimi, .omp, .qoder, .dsh, .codex, .terminal]
        kimiPort = try c.decodeIfPresent(Int.self, forKey: .kimiPort) ?? 58627
        kimiTokenPath = try c.decodeIfPresent(String.self, forKey: .kimiTokenPath) ?? "~/.kimi-code/server.token"
    }
    public var hasNativeAgents: Bool { enabledAgents.contains { [.omp, .qoder, .dsh, .codex].contains($0) } }
    /// Inert view state for an empty workspace; never listed, saved or connected.
    public static let unconfigured = SSHHost(id: UUID(uuidString: "00000000-0000-4000-8000-000000000000")!,
                                            name: "", destination: "", enabledAgents: [])
}

public struct Snapshot: Decodable, Sendable {
    public let version: String
    public let workspaces: [Workspace]
    public let tabs: [Tab]
    public let panes: [Pane]
    public let agents: [Pane]
    enum CodingKeys: String, CodingKey { case version, workspaces, tabs, panes, agents }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(String.self, forKey: .version)
        workspaces = try values.decode([Workspace].self, forKey: .workspaces)
        tabs = try values.decode([Tab].self, forKey: .tabs)
        let names = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.label) })
        func label(_ pane: Pane) -> Pane {
            var result = pane
            if let name = names[pane.tabID], !name.isEmpty, Int(name) == nil { result.tabLabel = name }
            return result
        }
        panes = try values.decode([Pane].self, forKey: .panes).map(label)
        agents = try values.decode([Pane].self, forKey: .agents).map(label)
    }
}

public struct Workspace: Decodable, Identifiable, Sendable {
    public let workspaceID: String
    public let label: String
    public var id: String { workspaceID }
    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id", label
    }
}

public struct Tab: Decodable, Identifiable, Sendable {
    public let tabID: String
    public let workspaceID: String
    public let label: String
    public var id: String { tabID }
    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id", workspaceID = "workspace_id", label
    }
}

public struct Pane: Decodable, Identifiable, Sendable {
    public let revision: UInt64?
    public let paneID: String
    public let terminalID: String
    public let workspaceID: String
    public let tabID: String
    public let cwd: String
    public let foregroundCwd: String?
    public let agent: String?
    public let agentStatus: String?
    public let terminalTitleStripped: String?
    public let title: String?
    public let name: String?
    public var tabLabel: String? = nil
    public var id: String { terminalID }
    public var directory: String { foregroundCwd ?? cwd }
    public var displayTitle: String {
        [title, name, tabLabel, terminalTitleStripped, agent, "终端"]
            .compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }!
    }
    public var status: String { agentStatus ?? "unknown" }
    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id", terminalID = "terminal_id"
        case workspaceID = "workspace_id", tabID = "tab_id"
        case cwd, foregroundCwd = "foreground_cwd", agent
        case agentStatus = "agent_status", terminalTitleStripped = "terminal_title_stripped"
        case title, name, revision
    }
}

public struct RemoteStatus: Decodable, Sendable {
    public let client: Client
    public let server: Server
    public struct Client: Decodable, Sendable { public let binary: String }
    public struct Server: Decodable, Sendable {
        public let running: Bool
        public let socket: String?
        public let version: String?
    }
}

public struct SnapshotResult: Decodable, Sendable { public let snapshot: Snapshot }

public enum Wire {
    public static func decode<Result: Decodable>(_ type: Result.Type, from data: Data) throws -> Result {
        let envelope = try JSONDecoder().decode(Envelope<Result>.self, from: data)
        if let error = envelope.error { throw WorkbenchError(error.message) }
        guard let result = envelope.result else { throw WorkbenchError("Herdr 未返回结果") }
        return result
    }
    private struct Envelope<Result: Decodable>: Decodable {
        let result: Result?
        let error: RemoteError?
    }
    private struct RemoteError: Decodable { let message: String }
}

public struct WorkbenchError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
