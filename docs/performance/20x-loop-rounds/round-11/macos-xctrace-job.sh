#!/bin/bash
# Round 11 attribution: Time Profiler over the cold projection bench (count=2000,
# 2,333 messages) at base d1590e4. Temporary bench-mode patch, reverted at the end.
# xctrace is for attribution only; it never replaces uncaptured A/B measurement.
set -e
cd "$HOME/_worktrees/20x-loop-20261112/perch"
echo "=== prepare $(date) ==="
git fetch origin
git checkout --detach d1590e4
echo "HEAD=$(git rev-parse HEAD)"
echo "porcelain_before=$(git status --porcelain | wc -l | tr -d ' ')"

echo "=== apply temporary cold-profile bench mode ==="
python3 - <<'PYEOF'
path = 'Tests/WorkbenchCoreTests/ProtocolTests.swift'
s = open(path).read()
anchor = 'case "1":'
assert anchor in s, 'anchor missing'
s = s.replace(anchor, 'case "cold-profile":\n            try benchPresentationColdProfile()\n            return\n        ' + anchor, 1)
open(path, 'w').write(s)
PYEOF
cat >> Tests/WorkbenchCoreTests/PresentationBench.swift <<'SWIFTEOF'

/// Attribution-only harness (never committed): loop the cold count=2000 fixture
/// with a fresh model per iteration so a Time Profiler capture gets enough samples.
func benchPresentationColdProfile() throws {
    func messages(_ count: Int) throws -> [KimiMessage] {
        let prose = Array(repeating: "这是一段用于验收的中文说明，包含 **结论**、`identifier` 与普通文本，混排 English words so that line breaking has to handle both scripts.", count: 3).joined(separator: "\n\n")
        var raw: [[String: Any]] = []
        for i in 0..<count {
            let id = String(format: "%05d", i)
            if i % 2 == 0 {
                raw.append(["id": id, "role": "user", "created_at": id,
                            "content": [["type": "text", "text": "第 \(i) 轮：\(prose)"]]])
            } else if i % 6 == 3 {
                raw.append(["id": id, "role": "assistant", "created_at": id, "content": [
                    ["type": "tool_use", "tool_call_id": "tool-\(i)", "tool_name": "Bash",
                     "input": ["command": "run fixture \(i)"]]]])
                raw.append(["id": id + "r", "role": "tool", "created_at": id, "content": [
                    ["type": "tool_result", "tool_call_id": "tool-\(i)", "is_error": false,
                     "output": ["rows": Array(repeating: "中文结果与 english identifiers", count: 16)]]]])
            } else {
                raw.append(["id": id, "role": "assistant", "created_at": id,
                            "content": [["type": "text", "text": "回答如下。\n\n\(prose)\n\n```swift\nlet value = \(i)\n```"]]])
            }
        }
        return try KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: raw))
    }
    let input = try messages(2000)
    var iterations = 0
    let deadline = Date().timeIntervalSince1970 + 25
    while Date().timeIntervalSince1970 < deadline {
        let model = ConversationPresentationModel(key: "cold-profile")
        _ = model.update(.init(messages: input, language: "zh")).rows.count
        iterations += 1
    }
    print("cold_profile_iterations=\(iterations)")
}
SWIFTEOF
echo "porcelain_applied=$(git status --porcelain | wc -l | tr -d ' ')"

echo "=== build $(date) ==="
swift build -c release --product WorkbenchChecks --scratch-path .build/round11-profile > /tmp/round11-profile-build.log 2>&1
echo "build_exit=$?"
BIN=.build/round11-profile/out/Products/Release/WorkbenchChecks
shasum -a 256 "$BIN"

echo "=== record $(date) ==="
mkdir -p .local/round11
rm -rf .local/round11/cold.trace .local/round11/toc.xml .local/round11/time-profile.xml
WORKBENCH_BENCH=cold-profile xcrun xctrace record --template 'Time Profiler' --launch "$BIN" --output .local/round11/cold.trace --time-limit 40s 2>&1 | tail -5
echo "record_exit=$?"

echo "=== export $(date) ==="
xcrun xctrace export --input .local/round11/cold.trace --toc --output .local/round11/toc.xml 2>&1 | tail -2
xcrun xctrace export --input .local/round11/cold.trace --xpath '/trace-toc/run[1]/data/table[@schema="time-profile"]' --output .local/round11/time-profile.xml 2>&1 | tail -2
ls -la .local/round11/

echo "=== revert $(date) ==="
git checkout -- Tests/
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
