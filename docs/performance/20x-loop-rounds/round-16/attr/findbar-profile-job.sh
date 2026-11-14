#!/bin/bash
# Round-16 attribution: Time Profiler over PURE cold find-bar queries (fresh
# ConversationSearch per iteration over the full streaming-bench window) at
# round-16 base 15f612f. Product relevance: ConversationFindBar (@State, dies
# with the bar) pays cold per open; UnifiedSearchView's HistorySearchWorker
# makes a FRESH ConversationSearch per query per session (cold per keystroke).
# Temporary loop-harness bench mode, reverted after. Attribution only.
set -e
cd "$HOME/_worktrees/20x-loop-20261112/perch"
echo "=== prepare $(date) ==="
git fetch origin
git checkout --detach 15f612f
echo "HEAD=$(git rev-parse HEAD)"
echo "porcelain_before=$(git status --porcelain | wc -l | tr -d ' ')"

echo "=== apply temporary profile loop mode ==="
python3 - <<'PYEOF'
path = 'Tests/WorkbenchCoreTests/ProtocolTests.swift'
s = open(path).read()
anchor = 'case "1":'
assert anchor in s, 'anchor missing'
s = s.replace(anchor, 'case "findbar-profile":\n            try benchFindBarColdProfileLoop()\n            return\n        ' + anchor, 1)
open(path, 'w').write(s)
PYEOF
cat >> Tests/WorkbenchCoreTests/StreamingBench.swift <<'SWIFTEOF'

/// Attribution-only harness (never committed): builds the streaming fixture
/// once, then loops fresh-instance full-window cold queries — the product's
/// per-open (find bar) and per-keystroke-per-session (workspace history
/// search) cost. Mirrors benchStreamingDelta's update-0 window (without the
/// first thinking delta, which cannot change cold cost materially).
func benchFindBarColdProfileLoop() throws {
    let seconds = Double(ProcessInfo.processInfo.environment["FINDBAR_PROFILE_SECONDS"] ?? "") ?? 20
    let completedTurns = Int(ProcessInfo.processInfo.environment["STREAMING_TURNS"] ?? "") ?? 230
    let cyclesPerTurn = 34
    let runningCycles = 20
    let thinking = String(repeating: "先确认当前实现与调用方的约束，再决定下一步 inspect the call sites. ", count: 9)
    let prompt = String(repeating: "请继续推进这个任务，修复问题并验证结果。", count: 8)
    let answer = (0..<12).map { "- 第 \($0) 项结论：`Identifier\($0)` 已经处理，并附带 English notes for the reader." }
        .joined(separator: "\n")
    let readOutput = (0..<60).map { "\($0)\tlet value\($0) = compute(\($0)) // 源代码行" }.joined(separator: "\n")
    let bashOutput = (0..<24).map { "PASS case \($0) 通过 in 0.0\($0)s" }.joined(separator: "\n")
    let grepOutput = (0..<16).map { "Sources/File\($0).swift:\($0 * 7): match 匹配行" }.joined(separator: "\n")
    let oldBlock = (0..<14).map { "    let value\($0) = compute(\($0)) // 原有实现" }.joined(separator: "\n")
    let newBlock = (0..<16).map { "    let value\($0) = computeFaster(\($0)) // 新实现" }.joined(separator: "\n")
    let written = (0..<90).map { "line \($0): 写入的文件内容 with mixed text" }.joined(separator: "\n")
    var raw: [[String: Any]] = []
    var clock = 0
    func stamp() -> String { clock += 1; return String(format: "2026-10-23T%09d", clock) }
    func cycle(turn: Int, step: Int) {
        let id = "t\(turn)-s\(step)"
        let tool: [String: Any]
        let output: String
        switch step % 10 {
        case 0, 3, 6:
            tool = ["type": "tool_use", "tool_call_id": "call-\(id)", "tool_name": "Read",
                    "input": ["file_path": "/repo/Sources/File\(step).swift"]]
            output = readOutput
        case 1, 4, 8:
            tool = ["type": "tool_use", "tool_call_id": "call-\(id)", "tool_name": "Bash",
                    "input": ["command": "swift test --filter Case\(step)", "description": "Run case \(step)"]]
            output = bashOutput
        case 2, 7:
            tool = ["type": "tool_use", "tool_call_id": "call-\(id)", "tool_name": "Grep",
                    "input": ["pattern": "compute\\(", "path": "/repo/Sources"]]
            output = grepOutput
        case 5:
            tool = ["type": "tool_use", "tool_call_id": "call-\(id)", "tool_name": "Edit",
                    "input": ["file_path": "/repo/Sources/File\(step).swift", "old_string": oldBlock, "new_string": newBlock]]
            output = "ok"
        default:
            tool = ["type": "tool_use", "tool_call_id": "call-\(id)", "tool_name": "Write",
                    "input": ["file_path": "/repo/Generated/Out\(turn)-\(step).swift", "content": written]]
            output = "ok"
        }
        var content: [[String: Any]] = [["type": "thinking", "thinking": thinking]]
        if step % 4 == 0 { content.append(["type": "text", "text": "检查第 \(step) 步的结果。"]) }
        content.append(tool)
        raw.append(["id": "a-\(id)", "role": "assistant", "created_at": stamp(), "content": content])
        raw.append(["id": "r-\(id)", "role": "tool", "created_at": stamp(), "content": [
            ["type": "tool_result", "tool_call_id": "call-\(id)", "is_error": false, "output": output]]])
    }
    func turn(_ turn: Int, running: Bool) {
        raw.append(["id": "u-\(turn)", "role": "user", "created_at": stamp(),
                    "content": [["type": "text", "text": "第 \(turn) 轮：\(prompt)"]]])
        for step in 0..<(running ? runningCycles : cyclesPerTurn) { cycle(turn: turn, step: step) }
        if !running {
            raw.append(["id": "f-\(turn)", "role": "assistant", "created_at": stamp(), "content": [
                ["type": "thinking", "thinking": thinking], ["type": "text", "text": "完成。\n\n\(answer)"]]])
        }
    }
    for index in 0...completedTurns { turn(index, running: index == completedTurns) }
    let snapshotJSON: [String: Any] = [
        "as_of_seq": 1, "epoch": "bench",
        "session": ["id": "s", "title": "bench", "updated_at": "1", "busy": true, "main_turn_active": true,
                    "metadata": ["cwd": "/repo"], "agent_config": ["model": "bench"]],
        "messages": ["items": raw, "has_more": false],
        "in_flight_turn": ["turn_id": 1, "assistant_text": "", "thinking_text": "开始思考。", "running_tools": []],
        "pending_approvals": [], "pending_questions": []
    ]
    let snapshotData = try JSONSerialization.data(withJSONObject: snapshotJSON)
    let conversation = KimiConversation(try KimiWire.decoder().decode(KimiSnapshot.self, from: snapshotData))
    let messages = conversation.displayMessages
    var samples: [Double] = []
    let deadline = Date().timeIntervalSince1970 + seconds
    while Date().timeIntervalSince1970 < deadline {
        let search = ConversationSearch()
        let t = benchNow()
        let found = search.hits(in: messages, query: "已经处理", running: true)
        samples.append((benchNow() - t) * 1000)
        precondition(found.hits.count >= completedTurns)
    }
    samples.sort()
    print("findbar_cold_iterations=\(samples.count)")
    print(String(format: "findbar_cold_median_ms=%.3f min_ms=%.3f max_ms=%.3f",
                 samples[samples.count / 2], samples[0], samples[samples.count - 1]))
}
SWIFTEOF
echo "porcelain_applied=$(git status --porcelain | wc -l | tr -d ' ')"

echo "=== build $(date) ==="
swift build -c release --product WorkbenchChecks --scratch-path .build/round16-profile > /tmp/round16-profile-build.log 2>&1
echo "build_exit=$?"
BIN="$PWD/.build/round16-profile/out/Products/Release/WorkbenchChecks"
shasum -a 256 "$BIN"

mkdir -p .local/round16
echo "=== timing context run (5s, untraced) $(date) ==="
FINDBAR_PROFILE_SECONDS=5 WORKBENCH_BENCH=findbar-profile "$BIN" 2>&1 | grep -E 'findbar_cold' || echo "timing_run_no_output"

echo "=== record findbar $(date) ==="
rm -rf .local/round16/findbar.trace .local/round16/findbar-time-profile.xml
WORKBENCH_BENCH=findbar-profile xcrun xctrace record --template 'Time Profiler' --launch "$BIN" --output .local/round16/findbar.trace --time-limit 40s 2>&1 | tail -2
echo "record_findbar_exit=$?"
xcrun xctrace export --input .local/round16/findbar.trace --xpath '/trace-toc/run[1]/data/table[@schema="time-profile"]' --output .local/round16/findbar-time-profile.xml 2>&1 | tail -1
ls -la .local/round16/

echo "=== revert $(date) ==="
git checkout -- Tests/
git status --porcelain | wc -l | tr -d ' ' | sed 's/^/porcelain_after=/'
echo "DONE $(date)"
