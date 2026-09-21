import Foundation
import WorkbenchCore

// Both binaries compile this identical workload against their own production core.
let label = CommandLine.arguments.dropFirst().first ?? "unknown"
let prose = String(repeating: "中文 **结果** with `identifier`, café and searchable needle.\n\n", count: 12)
var rows: [[String: Any]] = []
for turn in 0..<200 {
    rows.append(["id":"u\(turn)","role":"user","created_at":"\(turn)","content":[["type":"text","text":"第 \(turn) 轮任务"]]])
    rows.append(["id":"a\(turn)","role":"assistant","created_at":"\(turn)","content":[["type":"thinking","thinking":prose],["type":"text","text":prose + "\n| Key | Value |\n| --- | --- |\n| test | 42 |\n\n```swift\nlet result = 42\n```"]]])
}
let messagesData = try JSONSerialization.data(withJSONObject: rows)
let messages = try KimiWire.decoder().decode([KimiMessage].self, from: messagesData)
let envelope = try JSONSerialization.data(withJSONObject: ["code":0,"data":["items":rows,"has_more":false]])
let native = try JSONSerialization.data(withJSONObject: ["id":"fixture","provider":"omp","title":"Fixture","cwd":"/fixture","busy":false,"revision":1,"completed":200,"model":"fixture","messages":rows,"interactions":[]])
let event = Data(#"{"type":"assistant.delta","session_id":"fixture","payload":{"delta":"中文流式更新","raw_key":1}}"#.utf8)
var sink = 0
func benchmark(_ iterations: Int, _ body: () throws -> Int) rethrows -> [String: Double] {
    sink += try body()
    var samples: [Double] = []
    for _ in 0..<7 {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { sink += try body() }
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(iterations))
    }
    samples.sort()
    return ["median_ms":samples[3],"min_ms":samples[0],"max_ms":samples[6],"iterations_per_sample":Double(iterations)]
}
var results: [String: Any] = ["label":label,"turns":200,"messages":messages.count,"kimi_bytes":envelope.count,"native_bytes":native.count]
results["kimi_history_decode"] = try benchmark(10) {
    let value = try KimiWire.decode(KimiPage<KimiMessage>.self, from: envelope)
    precondition(value.items.count == 400)
    return value.items.count
}
results["native_snapshot_decode"] = try benchmark(10) {
#if PERFORMANCE_PATHS
    let value = try NativeAgentWire.decode(NativeSnapshotResponse.self, from: native).snapshot!
#else
    // Exact old refreshSelected/request path: validation, JSONValue, encoding, snapshot.
    let checked = try JSONDecoder().decode(JSONValue.self, from: native)
    precondition(checked["id"].string != nil)
    let raw = try KimiWire.decoder().decode(JSONValue.self, from: native)
    let value = try KimiWire.decoder().decode(NativeAgentSnapshot.self, from: JSONEncoder().encode(raw))
#endif
    precondition(value.messages.count == 400 && value.completed == 200)
    return value.messages.count
}
results["kimi_stream_event"] = try benchmark(2000) {
#if PERFORMANCE_PATHS
    let value = try KimiWire.decodeEvent(from: event)
#else
    let raw = try JSONDecoder().decode(JSONValue.self, from: event)
    precondition(raw["type"].string != "ack")
    let value = try KimiWire.decoder().decode(KimiEvent.self, from: event)
#endif
    precondition(value.payload["delta"].string == "中文流式更新")
    return value.payload["delta"].string!.count
}
#if PERFORMANCE_PATHS
let search = ConversationSearch()
#endif
var queries = ["needle", "result", "cafe", "中文"]
var index = 0
results["search_repeated"] = benchmark(8) {
    let query = queries[index % queries.count]; index += 1
#if PERFORMANCE_PATHS
    let hits = search.hits(in: messages, query: query, running: false)
#else
    let hits = ConversationSearch.hits(in: messages, query: query, running: false)
#endif
    precondition(!hits.isEmpty)
    return hits.count
}
results["search_cold"] = benchmark(3) {
#if PERFORMANCE_PATHS
    let hits = ConversationSearch().hits(in: messages, query: "needle", running: false)
#else
    let hits = ConversationSearch.hits(in: messages, query: "needle", running: false)
#endif
    precondition(hits.count == 2400)
    return hits.count
}
results["checksum"] = sink
let output = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: output, as: UTF8.self))
