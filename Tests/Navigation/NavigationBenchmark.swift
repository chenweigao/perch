import Foundation
import WorkbenchCore

// Measures the shared main-thread scoping work behind every sidebar/dashboard list
// update. It is not an end-to-end click latency: it excludes AppKit layout, text
// measurement and display submission, which are measured separately by the UI fixture.

private func sessions(_ count: Int, hosts: [UUID]) -> [WorkspaceSession] {
    let sections: [WorkQueueSection] = [.attention, .review, .running, .other]
    return (0..<count).map { index in
        let host = hosts[index % hosts.count]
        let kind: SessionKind = [.kimi, .omp, .qoder, .terminal][index % 4]
        return WorkspaceSession(
            reference: SessionReference(hostID: host, terminalID: "session-\(index)", kind: kind),
            title: "验收会话 \(index) · mixed Chinese and English title",
            directory: "/fixture/workspace/project-\(index % 37)/subdirectory",
            hostName: "fixture-host-\(index % hosts.count)",
            detail: "\(kind.label) · 结果待查看",
            online: index % 9 != 0,
            section: sections[index % sections.count],
            canMarkReviewed: index % 3 == 0,
            archived: index % 11 == 0,
            updatedAt: Double(count - index))
    }
}

private func measure(_ label: String, iterations: Int, _ body: () -> Int) {
    var samples: [Double] = []
    var checksum = 0
    for _ in 0..<iterations {
        let start = Date()
        checksum &+= body()
        samples.append(Date().timeIntervalSince(start) * 1_000)
    }
    let sorted = samples.sorted()
    let median = sorted[sorted.count / 2]
    let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
    let total = samples.reduce(0, +)
    let padded = label.padding(toLength: 46, withPad: " ", startingAt: 0)
    print(padded + String(format: "median %7.3f ms  p95 %7.3f ms  total %8.2f ms  n=%d  checksum=%d",
                          median, p95, total, iterations, checksum))
}

@main
struct NavigationBenchmark {
    static func main() {
        let hosts = (0..<3).map { _ in UUID() }
        print("scope evaluation per sidebar/dashboard update — pure model work, no AppKit layout")
        for count in [100, 500] {
            let all = sessions(count, hosts: hosts)
            let starred = Array(all.prefix(12).map(\.reference))
            let group = WorkItemGroup(name: "验收任务组", goal: "", nextStep: "",
                                      sessions: Array(all.prefix(count / 4).map(\.reference)))
            measure("\(count) sessions · no search", iterations: 200) {
                SessionCatalog.scope(all, starred: starred, group: nil, hostFilter: nil,
                                     search: "", onlyAttention: false, showArchived: false).sessions.count
            }
            measure("\(count) sessions · search keystroke", iterations: 200) {
                SessionCatalog.scope(all, starred: starred, group: nil, hostFilter: nil,
                                     search: "项目", onlyAttention: false, showArchived: false).sessions.count
            }
            measure("\(count) sessions · latin search keystroke", iterations: 200) {
                SessionCatalog.scope(all, starred: starred, group: nil, hostFilter: nil,
                                     search: "project-1", onlyAttention: false, showArchived: false).sessions.count
            }
            measure("\(count) sessions · task group scope", iterations: 200) {
                SessionCatalog.scope(all, starred: starred, group: group, hostFilter: nil,
                                     search: "", onlyAttention: false, showArchived: false).sessions.count
            }
            measure("\(count) sessions · archive scope", iterations: 200) {
                SessionCatalog.scope(all, starred: starred, group: nil, hostFilter: nil,
                                     search: "", onlyAttention: false, showArchived: true).sessions.count
            }
            print("")
        }
    }
}
