import Foundation
import WorkbenchCore

func checkRemoteSetup() async throws {
    let id = UUID()
    let old = Data("{\"id\":\"\(id)\",\"name\":\"Existing\",\"destination\":\"fixture\"}".utf8)
    let legacy = try JSONDecoder().decode(SSHHost.self, from: old)
    precondition(legacy.id == id && legacy.enabledAgents == RemoteSetup.agents && legacy.kimiPort == 58627)
    let host = SSHHost(id: id, name: "Kimi only", destination: "fixture", enabledAgents: [.kimi],
                       kimiPort: 60123, kimiTokenPath: "~/custom token/credential")
    let restored = try JSONDecoder().decode(SSHHost.self, from: JSONEncoder().encode(host))
    precondition(restored == host && !restored.hasNativeAgents)
    precondition(SSHHost.unconfigured.enabledAgents.isEmpty && SSHHost.unconfigured.destination.isEmpty)
    precondition(RemoteSetup.sshAliases("Host alpha beta # comment\nHost * !blocked *.example\nHost=gamma\nHost alpha") == ["alpha", "beta", "gamma"])
    try RemoteSetup.validate(host)
    var invalid = host; invalid.kimiPort = 70000
    do { try RemoteSetup.validate(invalid); preconditionFailure("invalid port accepted") } catch {}
    invalid = host; invalid.kimiTokenPath = "relative/token"
    do { try RemoteSetup.validate(invalid); preconditionFailure("relative token path accepted") } catch {}
    let hostilePath = "/tmp/quote'$(printf injected) token"
    let command = "printf '%s' " + RemoteSetup.remotePath(hostilePath)
    let output = try await SetupCommandRunner.run("/bin/sh", ["-c", command])
    precondition(String(decoding: output, as: UTF8.self) == hostilePath, "remote path must remain literal")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let child = folder.appendingPathComponent("a folder's $literal")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
    let listing = try await SetupCommandRunner.run("/bin/sh", ["-c", RemoteSetup.directoryListCommand(folder.path)])
    precondition(listing.split(separator: 0).map { String(decoding: $0, as: UTF8.self) } == [child.path])
    let args = try RemoteSetup.sshArguments("fixture", command: "true")
    precondition(args.contains("StrictHostKeyChecking=yes") && args.contains("BatchMode=yes"))
    do { _ = try RemoteSetup.terminalCommand(destination: "-oProxyCommand=bad"); preconditionFailure("SSH option accepted") } catch {}
    let started = Date()
    do {
        _ = try await SetupCommandRunner.run("/bin/sleep", ["5"], timeout: 0.1)
        preconditionFailure("timeout accepted")
    } catch { precondition(Date().timeIntervalSince(started) < 3) }
    let check = Task { try await SetupCommandRunner.run("/bin/sleep", ["5"]) }
    check.cancel()
    do { _ = try await check.value; preconditionFailure("cancelled check succeeded") }
    catch is CancellationError {} // Cancellation must not turn into a connection failure.
    print("PASS: remote setup migration, selected adapters, aliases, path quoting, timeout and cancellation")
}
