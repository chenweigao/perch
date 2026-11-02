import Foundation

public struct SSHHost: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var destination: String
    public var enabledAgents: [SessionKind]
    public var autoConnectSSH: Bool
    public var autoConnectHerdr: Bool
    public var kimiPort: Int
    public var kimiTokenPath: String
    public var localAgentPaths: [String: String] = [:]
    /// Perch starts this host's Kimi Web and may restart that instance, and only that
    /// instance, once every session in it is idle.
    public var kimiManaged = false
    /// Extra environment for the Kimi Web instance Perch starts on this host.
    public var kimiEnvironment: [String: String] = [:]
    public var isLocal: Bool { id == ExecutionEnvironment.localHostID }

    /// Where Kimi Web keeps its token unless `KIMI_CODE_HOME` moves it.
    public static let defaultKimiTokenPath = "~/.kimi-code/server.token"

    public init(id: UUID = UUID(), name: String, destination: String,
                enabledAgents: [SessionKind] = [.kimi, .omp, .qoder, .qoderintl, .dsh, .codex, .claude],
                kimiPort: Int = 58627, kimiTokenPath: String = SSHHost.defaultKimiTokenPath,
                autoConnectSSH: Bool = true, autoConnectHerdr: Bool = true) {
        self.id = id; self.name = name; self.destination = destination
        self.autoConnectSSH = autoConnectSSH; self.autoConnectHerdr = autoConnectHerdr
        self.enabledAgents = enabledAgents; self.kimiPort = kimiPort; self.kimiTokenPath = kimiTokenPath
    }
    enum CodingKeys: String, CodingKey { case id, name, destination, enabledAgents, kimiPort, kimiTokenPath, autoConnectSSH, autoConnectHerdr, localAgentPaths, kimiManaged, kimiEnvironment }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        destination = try c.decode(String.self, forKey: .destination)
        // Existing saved hosts retain their previous connections until reconfigured.
        enabledAgents = try c.decodeIfPresent([SessionKind].self, forKey: .enabledAgents) ?? [.kimi, .omp, .qoder, .qoderintl, .dsh, .codex, .claude]
        autoConnectSSH = try c.decodeIfPresent(Bool.self, forKey: .autoConnectSSH) ?? true
        autoConnectHerdr = try c.decodeIfPresent(Bool.self, forKey: .autoConnectHerdr) ?? true
        localAgentPaths = try c.decodeIfPresent([String: String].self, forKey: .localAgentPaths) ?? [:]
        kimiPort = try c.decodeIfPresent(Int.self, forKey: .kimiPort) ?? 58627
        kimiTokenPath = try c.decodeIfPresent(String.self, forKey: .kimiTokenPath) ?? SSHHost.defaultKimiTokenPath
        // Hosts saved before managed mode keep connecting to the service the user runs.
        kimiManaged = try c.decodeIfPresent(Bool.self, forKey: .kimiManaged) ?? false
        kimiEnvironment = try c.decodeIfPresent([String: String].self, forKey: .kimiEnvironment) ?? [:]
    }
    public var hasNativeAgents: Bool { enabledAgents.contains { [.omp, .qoder, .qoderintl, .dsh, .codex, .claude].contains($0) } }
    /// Inert view state for an empty workspace; never listed, saved or connected.
    public static let unconfigured = SSHHost(id: UUID(uuidString: "00000000-0000-4000-8000-000000000000")!,
                                            name: "", destination: "", enabledAgents: [])
}

public struct WorkbenchError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
