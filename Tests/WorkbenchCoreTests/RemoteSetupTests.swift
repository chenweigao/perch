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

private func probeBridge(home: URL) async throws -> BridgeProbeResult {
    let command = "HOME=\(SSHCommand.quote(home.path)); export HOME; " + RemoteSetup.bridgeProbeCommand
    return RemoteSetup.parseBridgeProbe(try await SetupCommandRunner.run("/bin/sh", ["-c", command]))
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
    // Hosts saved before managed mode keep connecting to the service the user runs.
    precondition(!legacy.kimiManaged && legacy.kimiEnvironment.isEmpty)
    var managedHost = host
    managedHost.kimiManaged = true; managedHost.kimiEnvironment = ["KIMI_CODE_INFINITE_RETRY": "true"]
    let restoredManaged = try JSONDecoder().decode(SSHHost.self, from: JSONEncoder().encode(managedHost))
    precondition(restoredManaged == managedHost && restoredManaged.kimiManaged)
    try RemoteSetup.validate(managedHost)
    var badEnvironment = managedHost; badEnvironment.kimiEnvironment = ["BAD NAME": "1"]
    do { try RemoteSetup.validate(badEnvironment); preconditionFailure("invalid environment name accepted") } catch {}
    let parsedEnvironment = try RemoteSetup.parseKimiEnvironment(" KIMI_CODE_INFINITE_RETRY=true\nB_2=x=y  EMPTY= ")
    precondition(parsedEnvironment == ["KIMI_CODE_INFINITE_RETRY": "true", "B_2": "x=y", "EMPTY": ""])
    precondition(RemoteSetup.formatKimiEnvironment(["B": "2", "A": "1"]) == "A=1 B=2")
    for invalid in ["1A=2", "NOVALUE", "名=1"] {
        do { _ = try RemoteSetup.parseKimiEnvironment(invalid); preconditionFailure("invalid environment accepted: \(invalid)") } catch {}
    }
    // Reports of `local-agent-service.py --agent kimi`: Perch's own instance and someone else's.
    let waiting = try RemoteSetup.parseKimiServiceEndpoint(Data(#"{"port":58628,"token":"t","owned":true,"runningVersion":"2.3.0","installedVersion":"2.4.0","restartReason":"update","restartPending":2}"#.utf8))
    precondition(waiting == KimiServiceEndpoint(port: 58628, token: "t", owned: true, installedVersion: "2.4.0",
                                                runningVersion: "2.3.0", restartReason: .update, restartPending: 2))
    let foreign = try RemoteSetup.parseKimiServiceEndpoint(Data(#"{"port":58627,"token":"t"}"#.utf8))
    precondition(!foreign.owned && !foreign.replaced && foreign.restartPending == nil && foreign.restartReason == nil)
    do { _ = try RemoteSetup.parseKimiServiceEndpoint(Data(#"{"port":58627}"#.utf8)); preconditionFailure("endpoint without a token accepted") } catch {}
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
    for shell in ["/bin/sh", "/bin/zsh"] {
        let listing = try await SetupCommandRunner.run(shell, ["-c", RemoteSetup.directoryListCommand(folder.path)])
        precondition(listing.split(separator: 0).map { String(decoding: $0, as: UTF8.self) } == [child.path])
    }
    let hidden = folder.appendingPathComponent(".hidden")
    let doubleDot = folder.appendingPathComponent("..hidden")
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: doubleDot, withIntermediateDirectories: false)
    let hiddenListing = try await SetupCommandRunner.run("/bin/zsh", ["-c", RemoteSetup.directoryListCommand(folder.path)])
    precondition(Set(hiddenListing.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }) == Set([child.path, hidden.path, doubleDot.path]))
    for directory in [child.path, hidden.path, doubleDot.path] {
        try FileManager.default.removeItem(atPath: directory)
    }
    let emptyListing = try await SetupCommandRunner.run("/bin/zsh", ["-c", RemoteSetup.directoryListCommand(folder.path)])
    precondition(emptyListing.isEmpty)

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

    // The streamed service script receives every argument literally, whatever the login shell.
    let echo = "import json,sys\nprint(json.dumps(sys.argv[1:]))\n"
    let hostileToken = "~/token's $(printf injected) dir/server.token"
    let ensure = RemoteSetup.kimiEnsureCommand(script: echo, port: 60123, tokenPath: hostileToken,
                                               environment: ["QUOTE": "it's $HOME", "KIMI_CODE_INFINITE_RETRY": "true"])
    for shell in ["/bin/sh", "/bin/zsh"] {
        let echoed = try JSONDecoder().decode([String].self, from: try await SetupCommandRunner.run(shell, ["-c", ensure]))
        precondition(echoed == ["--agent", "kimi", "--port", "60123", "--token-path", hostileToken,
                                "--env", "KIMI_CODE_INFINITE_RETRY=true", "--env", "QUOTE=it's $HOME"])
    }
    // The real script runs from the stream without an installed copy; a host without Kimi says so.
    let serviceScript = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("remote/local-agent-service.py")
    let serviceSource = try String(contentsOf: serviceScript, encoding: .utf8)
    let missingKimi = "PATH=/usr/bin:/bin; HOME=\(SSHCommand.quote(runtimeRoot.path)); export PATH HOME; "
        + RemoteSetup.kimiEnsureCommand(script: serviceSource, port: 60123, tokenPath: "~/.kimi-code/server.token", environment: [:])
    do {
        _ = try await SetupCommandRunner.run("/bin/sh", ["-c", missingKimi])
        preconditionFailure("a host without Kimi returned an endpoint")
    } catch { precondition(error.localizedDescription.contains("not found"), error.localizedDescription) }

    let bridgeHome = runtimeRoot.appendingPathComponent("bridge home")
    let bridgeDirectory = bridgeHome.appendingPathComponent(".local/share/agent-workbench/native")
    try FileManager.default.createDirectory(at: bridgeDirectory, withIntermediateDirectories: true)
    let uninstalledBridge = try await probeBridge(home: bridgeHome)
    precondition(uninstalledBridge == .missing)
    let bridgeScript = bridgeDirectory.appendingPathComponent("native-agent-service.py")
    try "#!/usr/bin/env python3\nROOT = 1\nSERVICE_VERSION = 7\n".write(to: bridgeScript, atomically: true, encoding: .utf8)
    let installedBridge = try await probeBridge(home: bridgeHome)
    precondition(installedBridge == .installed(version: 7))
    // A commented or renamed constant must not read as a compatible version.
    try "#!/usr/bin/env python3\n# SERVICE_VERSION = 7\nOTHER_VERSION = 9\n".write(to: bridgeScript, atomically: true, encoding: .utf8)
    let unreadableBridge = try await probeBridge(home: bridgeHome)
    precondition(unreadableBridge == .unreadable)
    precondition(RemoteSetup.parseBridgeProbe(Data("installed\0x\0".utf8)) == .invalid(output: "installed\0x\0"))

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
    print("PASS: remote setup migration, managed Kimi Web settings and command, Kimi runtime discovery, bridge version probe, aliases, path quoting, timeout and cancellation")
}
