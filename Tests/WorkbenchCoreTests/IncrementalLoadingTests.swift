import Foundation
import WorkbenchCore

func checkIncrementalLoading() throws {
    func wire(_ revision: Int, _ start: Int, _ total: Int, _ texts: [String], indices: [Int]? = nil,
              base: Int? = nil, epoch: String = "one", end: Int? = nil) throws -> NativeAgentSnapshot {
        var history: [String: Any] = ["epoch": epoch, "start": start, "total": total, "end": end ?? total]
        if let indices { history["indices"] = indices }
        if let base { history["baseRevision"] = base }
        let messages = texts.map { ["id": $0, "role": "assistant", "created_at": "0", "content": [["type": "text", "text": $0]]] as [String: Any] }
        let value: [String: Any] = ["id": "a", "provider": "omp", "title": "A", "cwd": "/fixture", "busy": false,
                                  "revision": revision, "completed": 0, "model": "m", "messages": messages, "interactions": [], "history": history]
        return try NativeAgentWire.decode(NativeAgentSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }
    if let path = ProcessInfo.processInfo.environment["PERCH_HISTORY_WIRE"] {
        struct BridgeFixture: Decodable {
            let first: NativeAgentSnapshot
            let page: NativeAgentSnapshot
            let delta: NativeAgentSnapshot
            let expected: [KimiMessage]
        }
        let fixture = try KimiWire.decoder().decode(BridgeFixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let result = try fixture.delta.applying(to: fixture.first.prepending(fixture.page))
        precondition(result.messages == fixture.expected, "Python-to-Swift history reconstruction differed from full snapshot")
        print("PASS: actual Python bridge packets reconstruct exactly in the Swift client")
    }
    let first = try wire(1, 2, 4, ["two", "three"])
    precondition(first.hasOlder)
    let page = try wire(2, 0, 4, ["zero", "one"], end: 2)
    let expanded = try first.prepending(page)
    precondition(expanded.revision == 1 && !expanded.hasOlder)
    let delta = try wire(2, 0, 5, ["edited three", "four"], indices: [3, 4], base: 1)
    do { _ = try wire(2, 2, 5, ["four"], indices: [4], base: 1).applying(to: expanded)
        preconditionFailure("A delta for the pre-expansion window was accepted") } catch {}
    let combined = try delta.applying(to: expanded)
    precondition(combined.messages.map(\.id) == ["zero", "one", "two", "edited three", "four"])
    let truncated = try wire(3, 0, 4, [], indices: [], base: 2).applying(to: combined)
    precondition(truncated.messages.count == 4)
    let reset = try wire(1, 0, 1, ["new history"], epoch: "two").applying(to: truncated)
    precondition(reset.messages.map(\.id) == ["new history"])
    for invalid in [try wire(2, 2, 5, ["gap"], indices: [4], base: 0),
                    try wire(2, 2, 6, ["gap"], indices: [5], base: 1),
                    try wire(2, 2, 4, ["wrong epoch"], indices: [3], base: 1, epoch: "two")] {
        do { _ = try invalid.applying(to: first); preconditionFailure("Invalid delta accepted") } catch {}
    }
    do { _ = try first.prepending(page).prepending(page); preconditionFailure("Duplicate page accepted") } catch {}
    print("PASS: transcript delta append/edit/truncate, prepend race, history epoch reset, gap and stale-base rejection")

    let host = UUID()
    func session(_ index: Int, archived: Bool = false) -> WorkspaceSession {
        WorkspaceSession(reference: .init(hostID: host, terminalID: "\(index)", kind: .omp),
            title: "任务 Café \(index)", directory: "/project/\(index % 20)", hostName: "Mac mini", detail: "OMP",
            online: index % 7 != 0, section: .other, canMarkReviewed: false, archived: archived)
    }
    let search = SessionDirectorySearch(), locale = Locale(identifier: "zh-Hans")
    let catalog = (0..<500).map { session($0, archived: $0 % 19 == 0) }
    for query in ["", "任务", "CAFE mini", "project/3 OMP", "不存在", "  任务   12 "] {
        let result = search.update(catalog, query: query, locale: locale)
        precondition(result.sessions == catalog.filter { !$0.archived && $0.matchesSearch(query) })
        precondition(result.online == result.sessions.filter(\.online))
        precondition(search.update(catalog, query: query, locale: locale).sessions == result.sessions)
    }
    precondition(search.update([], query: "任务", locale: locale).sessions.isEmpty)
    let terminal = WorkspaceSession(reference: .init(hostID: host, terminalID: "term", kind: .terminal), title: "Shell",
        directory: "/tmp", hostName: "Host", detail: "", online: true, section: .other, canMarkReviewed: false)
    precondition(search.update([terminal], query: "终端", locale: locale).sessions.count == 1)
    precondition(search.update([terminal], query: L("终端", locale: Locale(identifier: "en")), locale: Locale(identifier: "en")).sessions.count == 1)
    print("PASS: cached directory search matches prior Unicode/token semantics, catalog changes and locale invalidation")

    if let output = ProcessInfo.processInfo.environment["PERCH_SEARCH_BENCHMARK"] {
        var rows: [[String: Any]] = []
        for count in [500, 2000, 10000] {
            let items = (0..<count).map { session($0) }
            let cached = SessionDirectorySearch()
            _ = cached.update(items, query: "", locale: locale)
            var old: [Double] = [], optimized: [Double] = [], reused: [Double] = []
            for i in 0..<9 {
                let query = "任务 project/\(i)"
                var start = Date()
                let expected = items.filter { !$0.archived && $0.matchesSearch(query) }
                old.append(Date().timeIntervalSince(start) * 1000)
                start = Date()
                let result = cached.update(items, query: query, locale: locale)
                optimized.append(Date().timeIntervalSince(start) * 1000)
                precondition(result.sessions == expected)
                start = Date()
                _ = cached.update(items, query: query, locale: locale)
                reused.append(Date().timeIntervalSince(start) * 1000)
            }
            rows.append(["sessions": count, "old_one_pass_ms": old, "cached_new_query_ms": optimized, "cached_same_query_ms": reused])
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}
