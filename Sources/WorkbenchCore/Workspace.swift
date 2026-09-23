import Foundation

public enum SessionKind: String, Codable, Sendable {
    case terminal, kimi, omp, qoder, dsh, codex
    public var symbol: String {
        [Self.terminal: "terminal", .kimi: "sparkles", .omp: "bolt", .qoder: "curlybraces",
         .dsh: "brain.head.profile", .codex: "chevron.left.forwardslash.chevron.right"][self]!
    }
    public var label: String { [Self.terminal: L("终端"), .kimi: "Kimi", .omp: "OMP", .qoder: "Qoder CN", .dsh: "DeepSeek", .codex: "Codex"][self]! }
}

public struct SessionReference: Codable, Hashable, Identifiable, Sendable {
    public let hostID: UUID
    // Retain the stored key so existing workspaces migrate without losing references.
    public let terminalID: String
    public let kind: SessionKind
    public var id: String { kind == .terminal ? "\(hostID):\(terminalID)" : "\(hostID):\(kind.rawValue):\(terminalID)" }
    public init(hostID: UUID, terminalID: String, kind: SessionKind = .terminal) {
        self.hostID = hostID; self.terminalID = terminalID; self.kind = kind
    }
    private enum CodingKeys: String, CodingKey { case hostID, terminalID, kind }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try values.decode(UUID.self, forKey: .hostID)
        terminalID = try values.decode(String.self, forKey: .terminalID)
        kind = try values.decodeIfPresent(SessionKind.self, forKey: .kind) ?? .terminal
    }
}

public enum WorkspaceDestination: String, Codable, Sendable { case home, session }

public enum WorkQueueSection: String, CaseIterable, Sendable {
    case attention = "等你处理", review = "待查看结果", running = "运行中", other = "其他会话"
}

public struct WorkspaceSession: Identifiable, Equatable, Sendable {
    public let reference: SessionReference
    public let title: String
    public let directory: String
    public let hostName: String
    public let detail: String
    public let online: Bool
    public let section: WorkQueueSection
    public let canMarkReviewed: Bool
    public let archived: Bool
    public let updatedAt: Double
    public var id: String { reference.id }
    public func matchesSearch(_ query: String) -> Bool {
        let searchable = "\(title) \(directory) \(hostName) \(detail) \(reference.kind.label)"
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            searchable.localizedStandardContains(String($0))
        }
    }
    public init(reference: SessionReference, title: String, directory: String, hostName: String,
                detail: String, online: Bool, section: WorkQueueSection, canMarkReviewed: Bool, archived: Bool = false, updatedAt: Double = 0) {
        self.reference = reference; self.title = title; self.directory = directory; self.hostName = hostName
        self.detail = detail; self.online = online; self.section = section; self.canMarkReviewed = canMarkReviewed; self.archived = archived; self.updatedAt = updatedAt
    }
}

public struct WorkItemGroup: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var goal: String
    public var nextStep: String
    public var sessions: [SessionReference]
    public init(name: String, goal: String, nextStep: String, sessions: [SessionReference]) {
        self.name = name; self.goal = goal; self.nextStep = nextStep; self.sessions = sessions
    }
}

public struct SavedTerminal: Codable, Equatable, Sendable {
    public let session: SessionReference
    public let title: String
    public init(session: SessionReference, title: String) { self.session = session; self.title = title }
}

public struct LocalWorkspace: Codable, Equatable, Sendable {
    public var groups: [WorkItemGroup] = []
    public var pinned: [SavedTerminal] = []
    public var selectedTerminalID: String?
    public var selectedGroupID: UUID?
    public var lastSessionByGroup: [String: String] = [:]
    public var starred: [SessionReference] = []
    public var sessionTitles: [String: String] = [:]
    /// Sessions an automatic name was applied to. A manual rename or cleared
    /// title keeps this record, so automation never retitles a session the
    /// user has already touched.
    public var autoNamedSessions: Set<String> = []
    public var archivedTerminals: Set<SessionReference> = []
    public var destination: WorkspaceDestination = .home
    public var reviewedKimiUpdates: [String: String] = [:]
    public var reviewedRevisions: [String: UInt64] = [:]
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case sessionTitles, groups, pinned, selectedTerminalID, selectedGroupID, reviewedRevisions, destination, reviewedKimiUpdates, lastSessionByGroup, starred, archivedTerminals, autoNamedSessions
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        groups = try values.decode([WorkItemGroup].self, forKey: .groups)
        pinned = try values.decode([SavedTerminal].self, forKey: .pinned)
        sessionTitles = try values.decodeIfPresent([String: String].self, forKey: .sessionTitles) ?? [:]
        autoNamedSessions = try values.decodeIfPresent(Set<String>.self, forKey: .autoNamedSessions) ?? []
        starred = try values.decodeIfPresent([SessionReference].self, forKey: .starred) ?? pinned.map(\.session)
        archivedTerminals = try values.decodeIfPresent(Set<SessionReference>.self, forKey: .archivedTerminals) ?? []
        selectedTerminalID = try values.decodeIfPresent(String.self, forKey: .selectedTerminalID)
        selectedGroupID = try values.decodeIfPresent(UUID.self, forKey: .selectedGroupID)
        reviewedRevisions = try values.decode([String: UInt64].self, forKey: .reviewedRevisions)
        destination = try values.decodeIfPresent(WorkspaceDestination.self, forKey: .destination) ?? (selectedTerminalID == nil ? .home : .session)
        lastSessionByGroup = try values.decodeIfPresent([String: String].self, forKey: .lastSessionByGroup) ?? [:]
        reviewedKimiUpdates = try values.decodeIfPresent([String: String].self, forKey: .reviewedKimiUpdates) ?? [:]
    }

    public mutating func toggleStar(_ reference: SessionReference) {
        if starred.contains(reference) { starred.removeAll { $0 == reference } }
        else { starred.append(reference) }
    }
    public func displayTitle(_ title: String, for reference: SessionReference) -> String {
        sessionTitles[reference.id] ?? title
    }
    public mutating func rename(_ reference: SessionReference, title: String) {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionTitles[reference.id] = value.isEmpty ? nil : value
    }
    public mutating func removeSession(_ reference: SessionReference) {
        sessionTitles.removeValue(forKey: reference.id)
        autoNamedSessions.remove(reference.id)
        starred.removeAll { $0 == reference }; archivedTerminals.remove(reference)
        pinned.removeAll { $0.session == reference }
        for index in groups.indices { groups[index].sessions.removeAll { $0 == reference } }
        lastSessionByGroup = lastSessionByGroup.filter { $0.value != reference.id }
        reviewedRevisions.removeValue(forKey: reference.id); reviewedKimiUpdates.removeValue(forKey: reference.id)
        if selectedTerminalID == reference.id { selectedTerminalID = nil; destination = .home }
    }

    public func kimiSection(_ session: KimiSession, on hostID: UUID) -> WorkQueueSection {
        if session.pendingInteraction == "approval" || session.pendingInteraction == "question" { return .attention }
        if session.busy { return .running }
        if session.lastTurnReason == "failed" { return .attention }
        let ref = SessionReference(hostID: hostID, terminalID: session.id, kind: .kimi)
        if session.lastTurnReason == "completed" && reviewedKimiUpdates[ref.id] != session.updatedAt { return .review }
        return .other
    }
    public mutating func markReviewed(_ session: KimiSession, on hostID: UUID) {
        guard kimiSection(session, on: hostID) == .review else { return }
        reviewedKimiUpdates[SessionReference(hostID: hostID, terminalID: session.id, kind: .kimi).id] = session.updatedAt
    }

    public mutating func markReviewed(_ snapshot: NativeAgentSnapshot, on hostID: UUID) {
        guard !snapshot.busy, snapshot.interactions.isEmpty, snapshot.error == nil, snapshot.completed > 0 else { return }
        let id = SessionReference(hostID: hostID, terminalID: snapshot.id, kind: snapshot.provider).id
        // A catalog can already know about a newer completion than the displayed transcript.
        if let previous = reviewedKimiUpdates[id].flatMap(Int.init), snapshot.completed <= previous { return }
        reviewedKimiUpdates[id] = String(snapshot.completed)
    }

    public func needsReview(_ pane: Pane, on hostID: UUID) -> Bool {
        guard pane.status == "done" else { return false }
        guard let revision = pane.revision else { return true }
        return reviewedRevisions[SessionReference(hostID: hostID, terminalID: pane.id).id] != revision
    }

    public mutating func markReviewed(_ pane: Pane, on hostID: UUID) {
        guard pane.status == "done", let revision = pane.revision else { return }
        reviewedRevisions[SessionReference(hostID: hostID, terminalID: pane.id).id] = revision
    }
}

public enum WorkspaceFile {
    public static func load(from url: URL) throws -> LocalWorkspace {
        guard FileManager.default.fileExists(atPath: url.path) else { return LocalWorkspace() }
        return try JSONDecoder().decode(LocalWorkspace.self, from: Data(contentsOf: url))
    }
    public static func save(_ workspace: LocalWorkspace, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(workspace).write(to: url, options: .atomic)
    }
}
