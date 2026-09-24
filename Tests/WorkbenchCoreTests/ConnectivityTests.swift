import Foundation
import WorkbenchCore

func checkConnectivity() throws {
    // Local is its own environment, never ssh localhost.
    let local = ExecutionEnvironment.local
    let remote = ExecutionEnvironment.ssh(SSHHost(name: "dev-env", destination: "dev-env"))
    precondition(local.isLocal && !remote.isLocal)
    precondition(local.name == "本机")
    precondition(local.hostID == ExecutionEnvironment.localHostID)
    precondition(local.hostID != remote.hostID)
    // The same path and session name in both environments stay distinct sessions.
    let localSession = SessionReference(hostID: local.hostID, terminalID: "productB-shared", kind: .omp)
    let remoteSession = SessionReference(hostID: remote.hostID, terminalID: "productB-shared", kind: .omp)
    precondition(localSession.id != remoteSession.id)

    var localHost = SSHHost(id: ExecutionEnvironment.localHostID, name: "Local", destination: "",
                            enabledAgents: [.kimi, .codex], autoConnectHerdr: false)
    localHost.localAgentPaths = ["kimi": "/path with spaces/kimi"]
    let restored = try JSONDecoder().decode(SSHHost.self, from: JSONEncoder().encode(localHost))
    precondition(restored.isLocal && restored.localAgentPaths == localHost.localAgentPaths)
    precondition(!SSHHost(name: "Remote", destination: "host").isLocal)
    precondition(LocalAgentDiscovery.supported == [.kimi, .codex])
    precondition(LocalAgentDiscovery.executableName(.qoder) == "qoderclicn")

    // A GUI app does not inherit the shell PATH, so absolute defaults come first.
    let candidates = LocalAgentDiscovery.candidates(
        named: "omp", defaults: LocalAgentDiscovery.ompSearchPaths,
        path: "/opt/homebrew/bin:relative/bin::/usr/bin", home: "/Users/developer")
    precondition(candidates.first == "/opt/homebrew/bin/omp")
    precondition(candidates.contains("/Users/developer/.local/bin/omp"))
    precondition(candidates.contains("/usr/bin/omp"))
    // Relative PATH entries are dropped and duplicates collapse.
    precondition(!candidates.contains { !$0.hasPrefix("/") })
    precondition(candidates.filter { $0 == "/opt/homebrew/bin/omp" }.count == 1)
    // Discovery is a list of paths, not a shell string to evaluate.
    precondition(!candidates.contains { $0.contains("$") || $0.contains(";") || $0.contains("`") })
    // An empty PATH still yields the absolute defaults.
    precondition(!LocalAgentDiscovery.candidates(named: "omp", defaults: LocalAgentDiscovery.ompSearchPaths,
                                                 path: nil, home: "/Users/developer").isEmpty)

    // Version parsing accepts the installed format; unreadable output stays unknown.
    precondition(LocalAgentDiscovery.parseVersion("omp/17.1.4") == "17.1.4")
    precondition(LocalAgentDiscovery.parseVersion("omp v17.1.4\n") == "17.1.4")
    precondition(LocalAgentDiscovery.parseVersion("command not found") == nil)
    precondition(LocalAgentDiscovery.parseVersion("codex-cli 0.155.0-alpha.16.3") == "0.155.0-alpha.16.3")
    precondition(LocalAgentDiscovery.missingOMPHint.contains("不会自动安装"))

    // Launch arguments keep approvals explicit and never enable yolo.
    let launch = LocalOMPLaunch(executable: "/opt/homebrew/bin/omp",
                                workingDirectory: "/tmp/productB-work",
                                sessionDirectory: "/tmp/productB-state/omp-sessions")
    precondition(launch.usesExplicitApproval)
    precondition(!launch.arguments.contains("--auto-approve"))
    precondition(!launch.arguments.contains("yolo"))
    precondition(launch.arguments.contains("rpc-ui"))
    // Tools run in the chosen directory, and session state stays in an isolated dir.
    precondition(zip(launch.arguments, launch.arguments.dropFirst()).contains { $0 == "--cwd" && $1 == "/tmp/productB-work" })
    precondition(zip(launch.arguments, launch.arguments.dropFirst()).contains { $0 == "--session-dir" && $1 == "/tmp/productB-state/omp-sessions" })
    let resumed = LocalOMPLaunch(executable: "/opt/homebrew/bin/omp", workingDirectory: "/tmp/productB-work",
                                 sessionDirectory: "/tmp/productB-state/omp-sessions",
                                 resume: "/tmp/productB-state/omp-sessions/session.jsonl")
    precondition(resumed.arguments.contains("--resume"))

    // "Unknown command:" is the only signal that a verb does not exist.
    precondition(OMPCommandProbe.commandExists(errorMessage: nil))
    precondition(!OMPCommandProbe.commandExists(errorMessage: "Unknown command: interrupt"))
    // A wrong-argument error means the command is present, as observed for steer.
    precondition(OMPCommandProbe.commandExists(errorMessage: "undefined is not an object (evaluating 'A.startsWith')"))

    // Capabilities observed on the installed omp 17.1.4.
    let probe174 = OMPCommandProbe(prompt: true, abort: true, steer: true, followUp: true, sessionFile: true)
    let endpoint = AgentEndpoint.localOMP(version: "17.1.4", probe: probe174)
    precondition(endpoint.environment == .local && endpoint.kind == .omp)
    precondition(endpoint.canStartNativeConversation)
    precondition(endpoint.capabilities.stop && endpoint.capabilities.resume)
    // steer answers, but its effect on a live turn was not observed here.
    precondition(endpoint.capabilities.steer == .commandPresentEffectUnverified)
    precondition(endpoint.verificationNote.contains("未实机验证"))
    precondition(endpoint.runtimeVersion == "17.1.4")
    // An unreadable version grants nothing rather than assuming a newer release.
    let unknown = AgentEndpoint.localOMP(version: nil, probe: probe174)
    precondition(unknown.capabilities == .unknown)
    precondition(!unknown.canStartNativeConversation)
    precondition(unknown.verificationNote.contains("能力未知"))
    // A runtime missing steer must not be labelled as steerable.
    let noSteer = AgentEndpoint.localOMP(version: "17.1.4", probe: OMPCommandProbe(prompt: true, abort: true))
    precondition(noSteer.capabilities.steer == .unsupported)
    precondition(noSteer.capabilities.modes(isStreaming: true).isEmpty)
    // Endpoint identity separates environment and agent type.
    precondition(endpoint.id != AgentEndpoint(environment: remote, kind: .omp, capabilities: .unknown,
                                              verificationNote: "远端未验证").id)
    print("PASS: local/SSH environment identity, GUI-safe discovery paths, version gating, explicit approval launch and probe-derived capabilities")
}
