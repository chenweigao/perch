from pathlib import Path
root = Path(__file__).resolve().parent.parent
job = (root / 'docs/performance/20x-loop-rounds/round-34/attr/r34-attr.job').read_text()
start = job.index('    let completedTurns', job.index('func benchR34PagingProfile'))
end = job.index('    func ms(', start)
fixture = job[start:end]
(root / 'review-artifacts/reuse-probe.swift').write_text('import Foundation\nimport WorkbenchCore\n\n' + fixture + r'''
func field(_ value: Any, _ key: String) -> Any {
    Mirror(reflecting: value).children.first { $0.label == key }!.value
}
func history(_ snapshot: ConversationPresentationModel.Snapshot) -> AnyObject {
    field(snapshot, "history") as AnyObject
}
func turns(_ snapshot: ConversationPresentationModel.Snapshot) -> [AnyObject] {
    field(history(snapshot), "turns") as! [AnyObject]
}
func memoRows(_ turn: AnyObject) -> [ConversationPresentationModel.Row]? {
    let optional = field(turn, "presentation")
    guard let tuple = Mirror(reflecting: optional).children.first?.value else { return nil }
    return (field(tuple, "value") as! ConversationPresentationModel.Presentation).rows
}
func ptr(_ rows: [ConversationPresentationModel.Row]?) -> UInt? {
    rows?.withUnsafeBufferPointer { $0.baseAddress.map { UInt(bitPattern: $0) } }
}
let key = "host:kimi:s"
var latestMetrics: ConversationPresentationUpdateMetrics?
let model = ConversationPresentationModel(key: key, metricsHandler: { latestMetrics = $0 })
let tools = ToolVisibilityProjection()
var window = messages
func input(_ window: [KimiMessage]) -> ConversationPresentationModel.Input {
    .init(messages: window, isRunning: true, epoch: "bench", language: "zh")
}
var previousSnapshot = model.update(input(window))
_ = previousSnapshot.presented(activity: [:], foldsProcess: true, isRunning: true)
var previousSplit = tools.update(window, splittingAt: window.lastIndex(where: \.isUserPrompt)!, sessionID: key)
for page in 0..<20 {
    let priorTurns = turns(previousSnapshot)
    let priorMemos = Dictionary(uniqueKeysWithValues: priorTurns.map { (ObjectIdentifier($0), ptr(memoRows($0))) })
    let start = earlier.count - 100 * (page + 1)
    window = Array(earlier[start..<(start + 100)]) + window
    let snapshot = model.update(input(window))
    let updatedTurns = turns(snapshot)
    let sameTurns = updatedTurns.filter { priorMemos.keys.contains(ObjectIdentifier($0)) }
    let preexistingMemos = sameTurns.filter { ptr(memoRows($0)) == priorMemos[ObjectIdentifier($0)]! }
    _ = snapshot.presented(activity: [:], foldsProcess: true, isRunning: true)
    let retainedMemos = sameTurns.filter { ptr(memoRows($0)) == priorMemos[ObjectIdentifier($0)]! }
    let split = tools.update(window, splittingAt: window.lastIndex(where: \.isUserPrompt)!, sessionID: key)
    let oldChunks = Set(previousSplit.prefix.chunks!.map(ObjectIdentifier.init))
    let retainedChunks = split.prefix.chunks!.filter { oldChunks.contains(ObjectIdentifier($0)) }.count
    let metrics = latestMetrics!
    print("page=\(page + 1) messages=\(window.count) chunks_reused=\(retainedChunks) history_turn_refs_reused=\(sameTurns.count) existing_memos_before=\(preexistingMemos.count) existing_memos_after=\(retainedMemos.count) metrics_reused=\(metrics.reusedTurnCount) metrics_rebuilt=\(metrics.rebuiltTurnCount) history_container_same=\(history(snapshot) === history(previousSnapshot))")
    precondition(sameTurns.count >= 230 && retainedMemos.count == sameTurns.count)
    previousSnapshot = snapshot
    previousSplit = split
}
print("PASS: existing turn, chunk and presentation memo identities survive ordinal shifts; only History/global assembly is rebuilt")
''')
