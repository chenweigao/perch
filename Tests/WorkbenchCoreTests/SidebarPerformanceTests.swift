import Foundation
import WorkbenchCore

/// Compare the batched paths with the original per-group catalog scan, including
/// missing/duplicate memberships, duplicate catalog rows and host scoping.
func checkSidebarPerformance() {
    let host = UUID(), remote = UUID()
    func catalog(_ count: Int) -> [WorkspaceSession] {
        (0..<count).map { i in
            WorkspaceSession(reference: .init(hostID: i % 2 == 0 ? host : remote, terminalID: "session-\(i)", kind: .omp),
                title: "Task \(i)", directory: "/fixture", hostName: "fixture", detail: "fixture",
                online: i % 7 != 0, section: [.attention, .running, .review, .other][i % 4],
                canMarkReviewed: false, archived: i % 13 == 0, updatedAt: Double(i % 9))
        }
    }
    func groups(_ sessions: [WorkspaceSession], count: Int) -> [WorkItemGroup] {
        (0..<count).map { i in
            var group = WorkItemGroup(name: "Group \(i)", goal: "", nextStep: "",
                sessions: (0..<20).map { sessions[(i * 17 + $0) % sessions.count].reference })
            group.isPinned = i % 17 == 0
            group.lastOpenedAt = Double(i % 11)
            return group
        }
    }
    func ordered(_ groups: [WorkItemGroup]) -> [WorkItemGroup] {
        groups.enumerated().sorted {
            if $0.element.isPinned != $1.element.isPinned { return $0.element.isPinned }
            if $0.element.lastOpenedAt != $1.element.lastOpenedAt { return $0.element.lastOpenedAt > $1.element.lastOpenedAt }
            return $0.offset < $1.offset
        }.map(\.element)
    }
    func legacyShortcuts(_ groups: [WorkItemGroup], _ sessions: [WorkspaceSession], _ selected: UUID?) -> [TaskGroupSummary] {
        let all = ordered(groups).map { TaskGroupSummary(group: $0, sessions: sessions) }
        var result = all.filter { $0.group.isPinned } + all.filter { !$0.group.isPinned && ($0.group.lastOpenedAt > 0 || $0.id == selected) }.prefix(5)
        if let item = all.first(where: { $0.id == selected }), !result.contains(where: { $0.id == selected }) { result.append(item) }
        return result
    }
    var sessions = catalog(90)
    sessions.append(sessions[2])
    var goals = groups(sessions, count: 24)
    goals[0].sessions += [sessions[2].reference, sessions[2].reference, .init(hostID: remote, terminalID: "missing", kind: .omp)]
    goals.append(WorkItemGroup(name: "Empty", goal: "", nextStep: "", sessions: []))
    for hostID in [nil, host, remote] {
        precondition(TaskGroupSummary.ordered(groups: goals, sessions: sessions, hostID: hostID)
            == ordered(goals).map { TaskGroupSummary(group: $0, sessions: sessions, hostID: hostID) })
    }
    for selected in [nil] + goals.map({ Optional($0.id) }) {
        precondition(TaskGroupSummary.shortcuts(groups: goals, sessions: sessions, selectedID: selected)
            == legacyShortcuts(goals, sessions, selected))
    }
    for filter in SidebarRecentFilter.allCases {
        let pins = [sessions[2].reference, sessions[0].reference, sessions[2].reference, goals[0].sessions.last!]
        let active = sessions.filter { !$0.archived }
        let candidates = active.filter { !Set(pins).contains($0.reference) && (filter == .all || $0.section == .running) }
        let result = SidebarProjection(sessions: sessions, starred: pins, filter: filter)
        precondition(result.favorites == pins.compactMap { ref in active.first { $0.reference == ref } })
        precondition(result.recent == Array(candidates.prefix(20)) && result.totalRecentCount == candidates.count)
        precondition(result.attentionCount == active.filter { $0.online && $0.section == .attention }.count)
    }
    print("PASS: batched navigation matches original ordering, counts, host scope, missing and duplicate references")

    guard let output = ProcessInfo.processInfo.environment["PERCH_SIDEBAR_BENCHMARK"] else { return }
    var results: [[String: Any]] = []
    for (count, groupCount) in [(500, 30), (2000, 100), (10000, 300)] {
        let sessions = catalog(count), goals = groups(catalog(count), count: groupCount)
        var before: [Double] = [], after: [Double] = []
        for iteration in 0..<11 {
            let selected = goals[iteration % goals.count].id
            func old() -> [TaskGroupSummary] {
                let start = DispatchTime.now().uptimeNanoseconds
                let value = legacyShortcuts(goals, sessions, selected)
                before.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                return value
            }
            func new() -> [TaskGroupSummary] {
                let start = DispatchTime.now().uptimeNanoseconds
                let value = TaskGroupSummary.shortcuts(groups: goals, sessions: sessions, selectedID: selected)
                after.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                return value
            }
            if iteration % 2 == 0 { precondition(old() == new()) } else { precondition(new() == old()) }
        }
        results.append(["sessions": count, "groups": groupCount, "before_ms": before, "after_ms": after])
    }
    try! JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
}
