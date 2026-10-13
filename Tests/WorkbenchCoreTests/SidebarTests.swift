import Foundation
import WorkbenchCore

func checkSidebar() {
    checkSidebarPerformance()
    checkSidebarProjects()
    checkSidebarEvidence()
    let remote = UUID()
    func session(_ id: String, section: WorkQueueSection = .other, online: Bool = true,
                 archived: Bool = false, local: Bool = false) -> WorkspaceSession {
        WorkspaceSession(reference: SessionReference(hostID: local ? ExecutionEnvironment.localHostID : remote,
                         terminalID: id, kind: .omp), title: id, directory: "/tmp/sidebar",
                         hostName: local ? "本机" : "SSH", detail: section.rawValue, online: online,
                         section: section, canMarkReviewed: section == .review, archived: archived)
    }
    let pinned = session("pinned")
    let archived = session("archived", archived: true)
    let approval = session("approval", section: .attention)
    let localRun = session("local-run", section: .running, local: true)
    let sessions = [pinned, archived, approval, session("unread", section: .review),
                    session("offline-approval", section: .attention, online: false), localRun]
                 + (0..<30).map { session("recent-\($0)") }
    let pins = [archived.reference, pinned.reference]
    let all = SidebarProjection(sessions: sessions, starred: pins)
    expectEqual(all.favorites.map(\.id), [pinned.id])
    expectEqual(all.attentionCount, 1)
    expectEqual(all.recent.count, 20)
    expectEqual(all.totalRecentCount, 34)
    expectEqual(all.recent.first?.id, approval.id)
    expectFalse(all.recent.contains { $0.archived || $0.id == pinned.id })
    // A filter narrows the recents only: pins and the actionable count are the same list
    // whichever filter is active.
    let running = SidebarProjection(sessions: sessions, starred: pins, filter: .running)
    expectEqual(running.recent.map(\.id), [localRun.id])
    expectEqual(running.attentionCount, all.attentionCount)
    expectEqual(running.favorites.map(\.id), all.favorites.map(\.id))
    let offlineRun = session("offline-run", section: .running, online: false)
    let filteredOffline = SidebarProjection(sessions: [offlineRun, localRun], starred: [], filter: .running)
    expectEqual(filteredOffline.ungrouped.map(\.id), [localRun.id])
    expectEqual(filteredOffline.projects.flatMap(\.sessions).map(\.id), [localRun.id])
    let noRunning = SidebarProjection(sessions: [pinned, offlineRun], starred: [pinned.reference], filter: .running)
    precondition(noRunning.projects.isEmpty && noRunning.ungrouped.isEmpty && noRunning.favorites.count == 1,
                 "An empty running filter keeps pins but must not display empty projects or stale offline activity")
    print("PASS: stable sidebar pins, bounded recents, independent filters and actionable attention count")
}

private func checkSidebarEvidence() {
    let messages = try! KimiWire.decoder().decode([KimiMessage].self, from: Data(#"""
    [{"id":"one","role":"assistant","created_at":"2026-10-13T00:00:00Z","content":[
      {"type":"text","text":"cd /unrelated/prose"},
      {"type":"tool_use","input":{"path":"/work/tree-a/Sources/file.swift"}},
      {"type":"tool_use","input":{"command":"cd '/work/tree-a' && git status"}},
      {"type":"tool_use","input":{"command":"git -C /work/tree-b diff"}},
      {"type":"tool_use","input":{"command":"echo 'cd /unrelated/quoted'"}},
      {"type":"tool_use","input":{"command":"python3 - <<'PY'\ncd /unrelated/heredoc\nPY"}},
      {"type":"tool_use","input":{"command":"cd $(echo /unrelated/dynamic)"}}
    ]}]
    """#.utf8))
    let hints = SidebarProjectEvidence.directories(messages: messages, cwd: "/work")
    precondition(hints.contains("/work/tree-a") && hints.contains("/work/tree-b"))
    precondition(!hints.contains { $0.contains("unrelated") })
    let matches = Dictionary(uniqueKeysWithValues: Set(hints).map { path in
        (path, SidebarRepositoryMatch(directory: path.hasPrefix("/work/tree-a") ? "/repos/a" : "/repos/b", isRepository: true))
    })
    precondition(SidebarProjectEvidence.project(directories: hints, matches: matches) == "/repos/a")
    precondition(SidebarProjectEvidence.project(directories: hints, matches: [:]) == nil)
    print("PASS: project evidence uses real tool paths and literal navigation, rejects prose/quoted commands/heredocs/dynamic paths, and favors sustained repository work")
}

private func checkSidebarProjects() {
    let local = UUID(), remote = UUID()
    func item(_ id: String, _ path: String, host: UUID? = nil, archived: Bool = false) -> WorkspaceSession {
        WorkspaceSession(reference: .init(hostID: host ?? local, terminalID: id, kind: .codex),
            title: id, directory: path, hostName: host == remote ? "Remote" : "Local", detail: "",
            online: true, section: .other, canMarkReviewed: false, archived: archived)
    }
    let first = item("first", "/work/perch"), trailing = item("trailing", "/work/perch/"),
        other = item("other", "/another/perch"), crossHost = item("remote", "/work/perch", host: remote),
        temporary = item("temporary", ""), archived = item("archived", "/archived-only", archived: true)
    let many = (0..<35).map { item("session-\($0)", "/work/perch") }
    let sessions = [first, trailing, other, crossHost, temporary, archived] + many
    let projection = SidebarProjection(sessions: sessions, starred: [first.reference])
    precondition(projection.projects.count == 4, "Host and full path must distinguish same-name projects")
    let project = projection.projects.first { $0.location?.directory == "/work/perch" && $0.location?.hostID == local }!
    precondition(project.sessions.count == 36 && project.disambiguate)
    precondition(!projection.projects.flatMap(\.sessions).contains { $0.id == first.id || $0.archived })
    precondition(projection.projects.last?.location == nil)
    precondition(SidebarProjection(sessions: Array(sessions.reversed()), starred: []).projects.map(\.id) == projection.projects.map(\.id),
                 "Activity must not reshuffle project headers")
    let location = SidebarProjectLocation(hostID: local, directory: "/target/design", hostName: "Local")
    var workspace = LocalWorkspace()
    workspace.sidebarProjectLocations[crossHost.id] = location
    let moved = SidebarProjection(sessions: sessions, starred: [], projectLocations: workspace.sidebarProjectLocations)
    precondition(moved.projects.first { $0.id == location.id }?.sessions == [crossHost])
    precondition(crossHost.directory == "/work/perch" && crossHost.reference.hostID == remote)
    let roundTrip = try! JSONDecoder().decode(LocalWorkspace.self, from: JSONEncoder().encode(workspace))
    precondition(roundTrip.sidebarProjectLocations == workspace.sidebarProjectLocations)
    let search = SessionDirectorySearch(), locale = Locale(identifier: "en")
    precondition(search.update(sessions, query: "design", locale: locale).sessions.isEmpty)
    precondition(search.update(sessions, query: "design", locale: locale,
                               projectLocations: workspace.sidebarProjectLocations).sessions == [crossHost])
    precondition(search.update(sessions, query: "design", locale: locale).sessions.isEmpty)
    workspace.removeSession(crossHost.reference)
    precondition(workspace.sidebarProjectLocations.isEmpty)
    let duplicate = SidebarProjection(sessions: [first, first], starred: [])
    precondition(duplicate.projects.first?.sessions.count == 1)
    precondition(SidebarProjectLocation(hostID: local, directory: "/work/name ", hostName: "Local").directory == "/work/name ")
    let now = Date(timeIntervalSince1970: 2_000_000_000), zh = Locale(identifier: "zh-Hans")
    precondition(SessionTime.compactLabel(since: 0, now: now, locale: zh) == nil)
    precondition(SessionTime.compactLabel(since: now.timeIntervalSince1970 + 60, now: now, locale: zh) == "刚刚")
    precondition(SessionTime.compactLabel(since: now.timeIntervalSince1970 - 720, now: now, locale: zh) == "12分")
    precondition(SessionTime.compactLabel(since: now.timeIntervalSince1970 - 7200, now: now, locale: zh) == "2时")
    precondition(SessionTime.compactLabel(since: 1, now: now, locale: zh)!.count == 5)
    print("PASS: full project catalog, host/path identity, stable headers, pins, manual membership, persistence and project search")
}
