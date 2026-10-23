import Foundation
import WorkbenchCore

func checkRuntimeFreshness() throws {
    // Version output shapes printed by the installed runtimes.
    precondition(RuntimeVersion.parse("2.0.2") == "2.0.2")
    precondition(RuntimeVersion.parse("kimi 2.0.2\n") == "2.0.2")
    precondition(RuntimeVersion.parse("omp/17.1.4") == "17.1.4")
    precondition(RuntimeVersion.parse("command not found") == nil)
    // A prerelease suffix is kept, so two candidates do not compare equal.
    precondition(RuntimeVersion.parse("0.1.5-rc.1") == "0.1.5-rc.1")
    precondition(RuntimeVersion.compare(installed: "0.1.5-rc.2", running: "0.1.5-rc.1").isStale)

    // The package on disk and the process serving requests are separate readings.
    precondition(RuntimeVersion.compare(installed: "2.0.2", running: "2.0.2") == .current("2.0.2"))
    precondition(RuntimeVersion.compare(installed: "2.1.0", running: "2.0.2")
                 == .stale(installed: "2.1.0", running: "2.0.2"))
    // An unreadable version claims nothing rather than reporting agreement.
    precondition(RuntimeVersion.compare(installed: nil, running: "2.0.2") == .unknown)
    precondition(RuntimeVersion.compare(installed: "2.0.2", running: nil) == .unknown)
    precondition(RuntimeVersion.compare(installed: "unavailable", running: "2.0.2") == .unknown)
    precondition(!RuntimeVersion.compare(installed: "2.0.2", running: "2.0.2").isStale)

    // The notice names both versions, so the reader can act without guessing.
    let notice = RuntimeVersion.staleNotice(agent: "Kimi", installed: "2.1.0", running: "2.0.2")
    precondition(notice.contains("Kimi") && notice.contains("2.1.0") && notice.contains("2.0.2"))

    // Perch's own Kimi Web: silent unless a restart waits, then says what it waits for.
    let current = KimiServiceEndpoint(port: 58627, token: "t", owned: true, installedVersion: "2.3.0", runningVersion: "2.3.0")
    precondition(RuntimeVersion.managedNotice(current) == nil)
    let foreign = KimiServiceEndpoint(port: 58627, token: "t", restartReason: .update, restartPending: 2)
    precondition(RuntimeVersion.managedNotice(foreign) == nil, "only Perch's own instance is restarted")
    let busy = KimiServiceEndpoint(port: 58627, token: "t", owned: true, installedVersion: "2.4.0", runningVersion: "2.3.0",
                                   restartReason: .update, restartPending: 3)
    let waiting = RuntimeVersion.managedNotice(busy) ?? ""
    precondition(waiting.contains("2.4.0") && waiting.contains("2.3.0") && waiting.contains("3"))
    let unknown = KimiServiceEndpoint(port: 58627, token: "t", owned: true, installedVersion: "2.4.0", runningVersion: "2.3.0",
                                      restartReason: .update, restartPending: -1)
    let manual = RuntimeVersion.managedNotice(unknown) ?? ""
    precondition(manual.contains("2.4.0") && manual != waiting)
    let settings = KimiServiceEndpoint(port: 58627, token: "t", owned: true, installedVersion: "2.3.0", runningVersion: "2.3.0",
                                       restartReason: .settings, restartPending: 1)
    let configured = RuntimeVersion.managedNotice(settings) ?? ""
    precondition(!configured.isEmpty && !configured.contains("2.3.0") && configured.contains("1"))
    precondition(!RuntimeVersion.foreignServiceNote().isEmpty)

    // Start timestamps: fractional seconds, `Z` and both offset spellings parse.
    precondition(RuntimeVersion.startDate("2026-09-28T03:20:42.196Z") != nil)
    precondition(RuntimeVersion.startDate("2026-09-28T11:20:42+08:00") != nil)
    precondition(RuntimeVersion.startDate("2026-09-28T11:20:42+0800") != nil)
    precondition(RuntimeVersion.startDate("last Tuesday") == nil)
    precondition(RuntimeVersion.startDate(nil) == nil && RuntimeVersion.startDate("") == nil)
    precondition(RuntimeVersion.startedLabel(nil) == nil && RuntimeVersion.startedLabel("") == nil)
    precondition(RuntimeVersion.startedLabel("2026-09-28T03:20:42Z") != nil)

    // A detail line reports what was read, and only that.
    let running = RunningRuntime(version: "2.0.2", startedAt: "2026-09-28T03:20:42Z")
    let both = RuntimeVersion.detail(installed: "2.0.2", running: running)
    precondition(both.contains("2.0.2") && both.contains("·"))
    precondition(RuntimeVersion.detail(installed: "2.0.2", running: .unknown) == "2.0.2")
    precondition(RuntimeVersion.detail(installed: "", running: .unknown).isEmpty)
    let stale = RuntimeVersion.detail(installed: "2.1.0", running: RunningRuntime(version: "2.0.2"))
    precondition(stale.contains("2.1.0") && stale.contains("2.0.2"))

    // Envelope captured from `GET /api/v1/meta` on kimi web 2.0.2.
    let payload = Data("""
    {"code":0,"msg":"success","data":{"server_version":"2.0.2","server_id":"01M3K0EVYMQZDJ5M4DYRPGBKD6",\
    "started_at":"2026-09-28T03:20:42.196Z","backend":"v2","dangerous_bypass_auth":false}}
    """.utf8)
    let meta = try KimiWire.decode(KimiServerMeta.self, from: payload)
    precondition(meta.serverVersion == "2.0.2" && meta.serverId == "01M3K0EVYMQZDJ5M4DYRPGBKD6")
    precondition(meta.runtime.version == "2.0.2")
    precondition(RuntimeVersion.startDate(meta.runtime.startedAt) != nil)
    // A service that reports no version still connects, and stays unknown.
    let trimmed = try KimiWire.decode(KimiServerMeta.self, from: Data(#"{"code":0,"msg":"ok","data":{}}"#.utf8))
    precondition(trimmed.runtime.version == nil && trimmed.runtime.startedAt == nil)
    precondition(RuntimeVersion.compare(installed: "2.0.2", running: trimmed.runtime.version) == .unknown)

    print("PASS: version parsing, installed/serving comparison, stale and managed notices, start timestamps and meta decoding")
}
