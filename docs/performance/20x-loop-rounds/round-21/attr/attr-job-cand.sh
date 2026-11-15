#!/bin/bash
# Round-21 CANDIDATE-side attribution (byte-keyed tables, a7332c8 product
# state): decisive check on where the base's 29.56% NFC-hash share goes.
# Original header: MISS-DISTRIBUTION-FAITHFUL KB-scale long-tail profile
# (round-20 F3 lesson applied: unique text per update so the static tables
# never warm; sizes cycle 0.7-4KB like real streaming growth). Base = a559cea
# + long-tail bench extension (68b0ce4). Attribution only, never timing.
set -e
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261115"
mkdir -p "$LOGS/round21c-attr"
echo "=== prepare $(date) ==="
git fetch origin
git checkout --detach a559cea
git checkout -- . 2>/dev/null; git clean -fdq Tests/
git apply "$LOGS/r21-tests.patch" && echo tests_patch=ok
git apply "$LOGS/r21-product.patch" && echo product_patch=ok
echo "HEAD=$(git rev-parse HEAD) tests_state=68b0ce4 product_state=a7332c8-equivalent"
echo "porcelain_before=$(git status --porcelain | wc -l | tr -d ' ')"

echo "=== apply temporary profile loop mode ==="
python3 - <<'PYEOF'
path = 'Tests/WorkbenchCoreTests/ProtocolTests.swift'
s = open(path).read()
anchor = 'case "1":'
assert anchor in s, 'anchor missing'
s = s.replace(anchor, 'case "longtail-profile":\n            try benchLongTailProfileLoop()\n            return\n        ' + anchor, 1)
open(path, 'w').write(s)
PYEOF
cat >> Tests/WorkbenchCoreTests/PresentationBench.swift <<'SWIFTEOF'

/// Attribution-only harness (never committed): miss-heavy KB-scale long-tail
/// updates. Every update's tail text is UNIQUE (iteration counter suffix), so
/// NarrativeTextCache's static tables always miss and the full derivation
/// runs — the distribution the long-tail-stream bench measures. Text size
/// cycles 0.7-4KB within the run.
func benchLongTailProfileLoop() throws {
    func messages(_ count: Int) throws -> [KimiMessage] {
        var raw: [[String: Any]] = []
        for turn in 0..<count {
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
    var msgs = try messages(turns)
    let base = "第 199 轮回答：本轮完成了 **核心改动** 与验证，包含 `identifier` 与 English mixed text。"
    let chunk = "\n\n追加的流式正文，说明这一段的结论与后续步骤，包含 **强调**、`code`、以及普通中文叙述文本。"
    let model = ConversationPresentationModel(key: "longtail-profile")
    var snapshot = model.update(.init(messages: msgs, isRunning: true, language: "zh"))
    var iterations = 0
    let deadline = Date().timeIntervalSince1970 + 20
    while Date().timeIntervalSince1970 < deadline {
        iterations += 1
        let text = base + String(repeating: chunk, count: iterations % 30) + " #\(iterations)"
        let tail = try KimiWire.decoder().decode(KimiMessage.self, from: JSONSerialization.data(withJSONObject: [
            "id": "reply-00199", "role": "assistant", "created_at": "00199",
            "content": [["type": "text", "text": text]]] as [String: Any]))
        var next = msgs
        next[next.index(before: next.endIndex)] = tail
        msgs = next
        snapshot = model.update(.init(messages: next, isRunning: true, language: "zh"))
    }
    print("longtail_profile_iterations=\(iterations) rows=\(snapshot.rows.count)")
}
SWIFTEOF
echo "porcelain_applied=$(git status --porcelain | wc -l | tr -d ' ')"

echo "=== build $(date) ==="
swift build -c release --product WorkbenchChecks --scratch-path .build/round21c-profile > "$LOGS/round21c-attr/build.log" 2>&1
echo "build_exit=$?"
BIN="$PWD/.build/round21c-profile/out/Products/Release/WorkbenchChecks"
shasum -a 256 "$BIN"

echo "=== record longtail $(date) ==="
rm -rf "$LOGS/round21c-attr/longtail.trace" "$LOGS/round21c-attr/longtail-time-profile.xml"
WORKBENCH_BENCH=longtail-profile xcrun xctrace record --template 'Time Profiler' --launch "$BIN" --output "$LOGS/round21c-attr/longtail.trace" --time-limit 40s > "$LOGS/round21c-attr/record.log" 2>&1
echo "record_exit=$?"
tail -2 "$LOGS/round21c-attr/record.log"
xcrun xctrace export --input "$LOGS/round21c-attr/longtail.trace" --xpath '/trace-toc/run[1]/data/table[@schema="time-profile"]' --output "$LOGS/round21c-attr/longtail-time-profile.xml" > "$LOGS/round21c-attr/export.log" 2>&1
echo "export_exit=$?"
ls -la "$LOGS/round21c-attr/"

echo "=== revert $(date) ==="
git checkout -- Tests/
rm -rf .build/round21c-profile
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
