#!/bin/bash
# Round-20 attribution: Time Profiler over the presentation-token update path
# (narrative stage = ActivityNarrativeProjection.make is 75-91% of the token
# update on Mac per the built-in stage instrumentation) — at round-20 base
# c085fd9. Temporary loop-harness bench mode, reverted after.
# Attribution only, never timing.
set -e
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261115"
mkdir -p "$LOGS/round20-attr"
echo "=== prepare $(date) ==="
git fetch origin
git checkout --detach c085fd9
git checkout -- . 2>/dev/null || true; git clean -fdq Tests/
echo "HEAD=$(git rev-parse HEAD)"
echo "porcelain_before=$(git status --porcelain | wc -l | tr -d ' ')"

echo "=== apply temporary profile loop mode ==="
python3 - <<'PYEOF'
path = 'Tests/WorkbenchCoreTests/ProtocolTests.swift'
s = open(path).read()
anchor = 'case "1":'
assert anchor in s, 'anchor missing'
s = s.replace(anchor, 'case "presentation-profile":\n            try benchPresentationProfileLoop()\n            return\n        ' + anchor, 1)
open(path, 'w').write(s)
PYEOF
cat >> Tests/WorkbenchCoreTests/PresentationBench.swift <<'SWIFTEOF'

/// Attribution-only harness (never committed): loop tail-replacement updates
/// on the token-bench fixture shape so a Time Profiler capture gets dense
/// samples inside ActivityNarrativeProjection.make. Pre-decoded replacement
/// pool keeps JSON decoding out of the loop; harness ops between updates are
/// excludable by region (samples under make() frames).
func benchPresentationProfileLoop() throws {
    func fixture(turns: Int) throws -> [KimiMessage] {
        var raw: [[String: Any]] = []
        raw.reserveCapacity(turns * 4)
        for turn in 0..<turns {
            let id = String(format: "%05d", turn)
            let tool = "tool-\(id)"
            raw.append(["id": "user-\(id)", "role": "user", "created_at": id,
                        "content": [["type": "text", "text": "第 \(turn) 轮问题"]]])
            raw.append(["id": "work-\(id)", "role": "assistant", "created_at": id, "content": [
                ["type": "thinking", "thinking": "检查第 \(turn) 轮"],
                ["type": "tool_use", "tool_call_id": tool, "tool_name": "Read",
                 "input": ["path": "fixture-\(turn).txt"]]]])
            raw.append(["id": "result-\(id)", "role": "tool", "created_at": id, "content": [
                ["type": "tool_result", "tool_call_id": tool, "is_error": false,
                 "output": "第 \(turn) 轮结果"]]])
            raw.append(["id": "reply-\(id)", "role": "assistant", "created_at": id,
                        "content": [["type": "text", "text": "第 \(turn) 轮回答"]]])
        }
        return try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    let turns = 200
    var messages = try fixture(turns: turns)
    // Pre-decoded pool of growing tails (same shape as the bench's replacements).
    let poolSize = 1200
    let pool = try (0..<poolSize).map { update -> KimiMessage in
        let turn = turns - 1
        let id = String(format: "%05d", turn)
        return try KimiWire.decoder().decode(KimiMessage.self, from: JSONSerialization.data(withJSONObject: [
            "id": "reply-\(id)", "role": "assistant", "created_at": id,
            "content": [["type": "text", "text": "第 \(turn) 轮回答" + String(repeating: " 增量", count: update + 1)]]
        ] as [String: Any]))
    }
    let model = ConversationPresentationModel(key: "presentation-profile")
    var snapshot = model.update(.init(messages: messages, isRunning: true, language: "zh"))
    var iterations = 0
    let deadline = Date().timeIntervalSince1970 + 20
    while Date().timeIntervalSince1970 < deadline {
        var next = messages
        next[next.index(before: next.endIndex)] = pool[iterations % poolSize]
        messages = next
        snapshot = model.update(.init(messages: next, isRunning: true, language: "zh"))
        iterations += 1
    }
    print("presentation_profile_iterations=\(iterations) rows=\(snapshot.rows.count)")
}
SWIFTEOF
echo "porcelain_applied=$(git status --porcelain | wc -l | tr -d ' ')"

echo "=== build $(date) ==="
swift build -c release --product WorkbenchChecks --scratch-path .build/round20-profile > "$LOGS/round20-attr/build.log" 2>&1
echo "build_exit=$?"
BIN="$PWD/.build/round20-profile/out/Products/Release/WorkbenchChecks"
shasum -a 256 "$BIN"

echo "=== record presentation $(date) ==="
rm -rf "$LOGS/round20-attr/presentation.trace" "$LOGS/round20-attr/presentation-time-profile.xml"
WORKBENCH_BENCH=presentation-profile xcrun xctrace record --template 'Time Profiler' --launch "$BIN" --output "$LOGS/round20-attr/presentation.trace" --time-limit 40s > "$LOGS/round20-attr/record.log" 2>&1
echo "record_exit=$?"
tail -2 "$LOGS/round20-attr/record.log"
xcrun xctrace export --input "$LOGS/round20-attr/presentation.trace" --xpath '/trace-toc/run[1]/data/table[@schema="time-profile"]' --output "$LOGS/round20-attr/presentation-time-profile.xml" > "$LOGS/round20-attr/export.log" 2>&1
echo "export_exit=$?"
ls -la "$LOGS/round20-attr/"

echo "=== revert $(date) ==="
git checkout -- Tests/
rm -rf .build/round20-profile
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
