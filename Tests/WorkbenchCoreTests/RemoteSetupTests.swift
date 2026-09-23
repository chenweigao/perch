import Foundation
import WorkbenchCore

private func writeExecutable(_ url: URL, _ contents: String) throws {
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func probeKimi(path: URL) async throws -> KimiRuntimeProbeResult {
    let command = "PATH=\(SSHCommand.quote(path.path)); export PATH; " + RemoteSetup.kimiRuntimeProbeCommand
    let output = try await SetupCommandRunner.run("/bin/sh", ["-c", command])
    return RemoteSetup.parseKimiRuntimeProbe(output)
}

func checkRemoteSetup() async throws {
    let id = UUID()
    let old = Data("{\"id\":\"\(id)\",\"name\":\"Existing\",\"destination\":\"fixture\"}".utf8)
    let legacy = try JSONDecoder().decode(SSHHost.self, from: old)
    precondition(legacy.id == id && legacy.enabledAgents == RemoteSetup.agents && legacy.kimiPort == 58627)
    precondition(legacy.autoConnectSSH && legacy.autoConnectHerdr)
    let host = SSHHost(id: id, name: "Kimi only", destination: "fixture", enabledAgents: [.kimi],
                       kimiPort: 60123, kimiTokenPath: "~/custom token/credential",
                       autoConnectSSH: false, autoConnectHerdr: false)
    let restored = try JSONDecoder().decode(SSHHost.self, from: JSONEncoder().encode(host))
    precondition(restored == host && !restored.hasNativeAgents)
    let codexHost = SSHHost(id: id, name: "Codex", destination: "fixture", enabledAgents: [.codex])
    precondition(codexHost.hasNativeAgents)
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

    let runtimeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: runtimeRoot) }

    let directBin = runtimeRoot.appendingPathComponent("direct bin")
    try FileManager.default.createDirectory(at: directBin, withIntermediateDirectories: false)
    let directKimi = directBin.appendingPathComponent("kimi")
    try writeExecutable(directKimi, "#!/bin/sh\nprintf 'kimi-code 2.0.2'")
    guard case .ready(let directRuntime) = try await probeKimi(path: directBin) else {
        preconditionFailure("PATH Kimi was not detected")
    }
    precondition(directRuntime.path == directKimi.path && directRuntime.version == "kimi-code 2.0.2" && directRuntime.source == .path)

    let tools = runtimeRoot.appendingPathComponent("tools")
    let prefix = runtimeRoot.appendingPathComponent("npm prefix")
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try writeExecutable(tools.appendingPathComponent("node"), "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then printf 'v22.19.0'; exit 0; fi\nif [ \"$1\" = \"-e\" ]; then exit 0; fi\nexit 1")
    try writeExecutable(tools.appendingPathComponent("npm"), "#!/bin/sh\nif [ \"$1\" = \"prefix\" ] && [ \"$2\" = \"-g\" ]; then printf '%s' \(SSHCommand.quote(prefix.path)); exit 0; fi\nexit 1")
    let prefixedKimi = prefix.appendingPathComponent("bin/kimi")
    try writeExecutable(prefixedKimi, "#!/bin/sh\nprintf 'kimi-code 2.0.2'")
    guard case .ready(let prefixedRuntime) = try await probeKimi(path: tools) else {
        preconditionFailure("npm-prefix Kimi was not detected")
    }
    precondition(prefixedRuntime.path == prefixedKimi.path && prefixedRuntime.source == .npmPrefix)

    try FileManager.default.removeItem(at: prefixedKimi)
    guard case .missing(let checkedPrefix) = try await probeKimi(path: tools) else {
        preconditionFailure("missing npm-prefix Kimi was not reported")
    }
    precondition(checkedPrefix == prefix.path)
    try writeExecutable(tools.appendingPathComponent("npm"), "#!/bin/sh\nexit 3")
    let npmFailure = try await probeKimi(path: tools)
    precondition(npmFailure == .npmFailed)
    try writeExecutable(tools.appendingPathComponent("node"), "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then printf 'v22.18.0'; exit 0; fi\nexit 1")
    guard case .nodeTooOld(let version) = try await probeKimi(path: tools) else {
        preconditionFailure("old Node.js was not reported")
    }
    precondition(version == "v22.18.0")

    let emptyPath = runtimeRoot.appendingPathComponent("empty")
    try FileManager.default.createDirectory(at: emptyPath, withIntermediateDirectories: false)
    let missingRuntime = try await probeKimi(path: emptyPath)
    precondition(missingRuntime == .npmMissing)

    let npmOnlyPath = runtimeRoot.appendingPathComponent("npm only")
    try FileManager.default.createDirectory(at: npmOnlyPath, withIntermediateDirectories: false)
    try writeExecutable(npmOnlyPath.appendingPathComponent("npm"), "#!/bin/sh\nexit 0")
    let nodeMissingRuntime = try await probeKimi(path: npmOnlyPath)
    precondition(nodeMissingRuntime == .nodeMissing)

    let quotedBin = runtimeRoot.appendingPathComponent("quoted bin's")
    try FileManager.default.createDirectory(at: quotedBin, withIntermediateDirectories: false)
    let startedKimi = quotedBin.appendingPathComponent("kimi")
    let argumentsFile = runtimeRoot.appendingPathComponent("started-arguments")
    try writeExecutable(startedKimi, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \(SSHCommand.quote(argumentsFile.path))")
    let startCommand = "HOME=\(SSHCommand.quote(runtimeRoot.path)); export HOME; "
        + RemoteSetup.kimiStartCommand(binaryPath: startedKimi.path, port: 60123)
    _ = try await SetupCommandRunner.run("/bin/sh", ["-c", startCommand])
    for _ in 0..<50 where !FileManager.default.fileExists(atPath: argumentsFile.path) {
        try await Task.sleep(for: .milliseconds(20))
    }
    let startedArguments = try String(contentsOf: argumentsFile, encoding: .utf8).split(separator: "\n").map(String.init)
    precondition(startedArguments == ["web", "--host", "127.0.0.1", "--port", "60123", "--no-open"])

    let args = try RemoteSetup.sshArguments("fixture", command: "true")
    precondition(args.contains("StrictHostKeyChecking=yes") && args.contains("BatchMode=yes"))
    do { _ = try RemoteSetup.terminalCommand(destination: "-oProxyCommand=bad"); preconditionFailure("SSH option accepted") } catch {}
    let started = Date()
    do {
        _ = try await SetupCommandRunner.run("/bin/sleep", ["5"], timeout: 0.1)
        preconditionFailure("timeout accepted")
    } catch { precondition(Date().timeIntervalSince(started) < 3) }
    let check = Task { try await SetupCommandRunner.run("/bin/sleep", ["5"]) }
    try await Task.sleep(for: .milliseconds(100))
    let cancelled = Date()
    check.cancel()
    do { _ = try await check.value; preconditionFailure("cancelled check succeeded") }
    catch is CancellationError {} // Cancellation must not turn into a connection failure.
    precondition(Date().timeIntervalSince(cancelled) < 3)
    print("PASS: remote setup migration, Kimi runtime discovery, safe startup, aliases, path quoting, timeout and cancellation")
}
