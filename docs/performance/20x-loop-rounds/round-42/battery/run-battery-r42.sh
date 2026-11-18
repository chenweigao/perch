#!/bin/bash
# Round-42 mutation battery: displayMessages box-per-lineage memo.
# Killable mutants must DIE via checkDisplayMessagesMemo (twin divergence
# or anti-blind); two documented EQUIVALENT mutants must survive
# (tool.progress / reconcile-tail replacements guard fields the getter
# output does not depend on — belt-and-braces replacements).
set -u
cd /home/<dev>/.t3/worktrees/perch/t3-b3eb4bba-c5db753ed6879e15
export PATH=/home/<dev>/.local/swift/6.3.3/usr/bin:$PATH
SRC_CONV=Sources/WorkbenchCore/KimiProtocol.swift
SRC_TL=Sources/WorkbenchCore/ConversationTimeline.swift
OUT=.local/round42/battery
mkdir -p "$OUT"
cp "$SRC_CONV" "$OUT/pristine-KimiProtocol.swift"
cp "$SRC_TL" "$OUT/pristine-ConversationTimeline.swift"

restore() {
  cp "$OUT/pristine-KimiProtocol.swift" "$SRC_CONV"
  cp "$OUT/pristine-ConversationTimeline.swift" "$SRC_TL"
}

run_mutant() {
  local name="$1" expect="${2:-die}"
  swift build --product WorkbenchChecks > "$OUT/$name-build.log" 2>&1
  local bexit=$?
  if [ $bexit != 0 ]; then echo "$name BUILD-FAIL"; grep -m2 "error:" "$OUT/$name-build.log"; restore; return; fi
  timeout 1200 .build/debug/WorkbenchChecks > "$OUT/$name.log" 2>&1
  local exit=$?
  local killer
  killer=$(grep -m1 -E "Precondition failed|Fatal error" "$OUT/$name.log" | head -1)
  if [ "$expect" = equivalent ]; then
    if [ $exit == 0 ]; then echo "$name SURVIVED (expected — documented equivalent mutant)"
    else echo "$name DIED UNEXPECTEDLY exit=$exit killer=$killer"; fi
  elif [ $exit != 0 ]; then echo "$name DIED exit=$exit killer=$killer"
  else echo "$name SURVIVED (exit=0) — PIN GAP"; fi
  restore
}
mutate() {
  restore
  python3 - "$1" "$2" "$3" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
old = old.encode().decode('unicode_escape')
new = new.encode().decode('unicode_escape')
assert old in s, "anchor not found in " + path + ": " + old[:80]
s = s.replace(old, new, 1)
open(path, 'w').write(s)
PYEOF
}

echo "=== r42 battery start $(date) ==="
restore
swift build --product WorkbenchChecks > "$OUT/m0-build.log" 2>&1
.build/debug/WorkbenchChecks > "$OUT/m0-pristine.log" 2>&1
echo "m0-pristine exit=$? (must be 0)"

# M1: drop the box replacement on the streaming delta path — the memo then
# serves the previous delta's array (twin divergence at assistant-delta-1).
mutate "$SRC_CONV" 'self.live = live; notice = nil\n            displayMemo = DisplayMemoBox()' 'self.live = live; notice = nil'
run_mutant m1-delta-fork-drop

# M2: drop the replacement in prepend(page) — stale across window growth.
mutate "$SRC_CONV" 'messages = older + messages; hasOlder = page.hasMore\n        displayMemo = DisplayMemoBox()' 'messages = older + messages; hasOlder = page.hasMore'
run_mutant m2-prepend-fork-drop

# M3: box never stores — hits stay 0 (anti-blind kill).
mutate "$SRC_TL" 'if cached == nil { cached = computed }' '// never store'
run_mutant m3-never-store

# M4: box ignores the cache — always computes (anti-blind kill: hits == 0).
mutate "$SRC_TL" 'if let cached {\n            hits += 1' 'if false, let cached = cached {\n            hits += 1'
run_mutant m4-cache-blind

# M5 (EQUIVALENT): tool.progress replacement — lastProgress is not part of
# the getter output; removal must survive.
mutate "$SRC_CONV" 'live?.runningTools[index].lastProgress = p["update"]\n                displayMemo = DisplayMemoBox()' 'live?.runningTools[index].lastProgress = p["update"]'
run_mutant m5-toolprogress-fork-drop equivalent

# M6 (EQUIVALENT): reconcile-tail replacement — the `self =` inside
# reconcile already adopts a fresh (empty) box; removal must survive.
mutate "$SRC_CONV" '            if !older.isEmpty { messages = older + messages; hasOlder = hadLoadedOlder }\n        }\n        displayMemo = DisplayMemoBox()' '            if !older.isEmpty { messages = older + messages; hasOlder = hadLoadedOlder }\n        }'
run_mutant m6-reconcile-tail-fork-drop equivalent

restore
git diff --stat -- Sources
echo "=== r42 battery done $(date) ==="
