#!/bin/bash
# Round-41 mutation battery v2 (at v6=f69883a3): the original 10 mutants
# plus 4 revert-mutants proving the strengthened pin kills each review
# F1-F4 fix when reverted. Every mutant must DIE (nonzero WorkbenchChecks
# exit); m4 is a documented EQUIVALENT mutant (see report) and is expected
# to survive.
set -u
cd /home/<dev>/.t3/worktrees/perch/t3-b3eb4bba-c5db753ed6879e15
export PATH=/home/<dev>/.local/swift/6.3.3/usr/bin:$PATH
SRC=Sources/WorkbenchCore/ActivityNarrative.swift
OUT=.local/round41/battery-v2
mkdir -p "$OUT"
cp "$SRC" "$OUT/pristine.swift"

run_mutant() {
  local name="$1" expect="${2:-die}"
  swift build --product WorkbenchChecks > "$OUT/$name-build.log" 2>&1
  local bexit=$?
  if [ $bexit != 0 ]; then echo "$name BUILD-FAIL"; grep -m2 "error:" "$OUT/$name-build.log"; cp "$OUT/pristine.swift" "$SRC"; return; fi
  timeout 1200 .build/debug/WorkbenchChecks > "$OUT/$name.log" 2>&1
  local exit=$?
  local killer
  killer=$(grep -m1 -E "Precondition failed|Fatal error" "$OUT/$name.log" | head -1)
  if [ "$expect" = equivalent ]; then
    if [ $exit == 0 ]; then echo "$name SURVIVED (expected — documented equivalent mutant)"
    else echo "$name DIED UNEXPECTEDLY exit=$exit killer=$killer"; fi
  elif [ $exit != 0 ]; then echo "$name DIED exit=$exit killer=$killer"
  else echo "$name SURVIVED (exit=0) — PIN GAP"; fi
  cp "$OUT/pristine.swift" "$SRC"
}
mutate() {
  cp "$OUT/pristine.swift" "$SRC"
  python3 - "$1" "$2" "$3" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open('Sources/WorkbenchCore/ActivityNarrative.swift').read()
old = old.encode().decode('unicode_escape')
new = new.encode().decode('unicode_escape')
assert old in s, "anchor not found: " + old[:80]
s = s.replace(old, new, 1)
open(path, 'w').write(s)
PYEOF
}

echo "=== battery-v2 start $(date) ==="
cp "$OUT/pristine.swift" "$SRC"
swift build --product WorkbenchChecks > "$OUT/m0-build.log" 2>&1
.build/debug/WorkbenchChecks > "$OUT/m0-pristine.log" 2>&1
echo "m0-pristine exit=$? (must be 0)"

mutate "$SRC" 'if Self.isTrimScalar(value) { headPending = []; return }' 'if false && Self.isTrimScalar(value) { headPending = []; return }'
run_mutant m1-headtrim-drop
mutate "$SRC" 'zoneLen = Self.isTrimScalar(UInt32(byte)) ? zoneLen + 1 : 0' 'zoneLen = 0'
run_mutant m2-zone-drop-ascii
mutate "$SRC" 'NarrativePhaseScan.scan(&tail, buf, limit: lenTrimmed, count: lenTrimmed)' 'NarrativePhaseScan.scan(&tail, buf, limit: phaseState.offset, count: lenTrimmed)'
run_mutant m3-phase-tail-drop
mutate "$SRC" 'if nonEmpty { chosen = (kind, start); break }' 'chosen = (kind, start); break'
run_mutant m4-gate-freeze equivalent
mutate "$SRC" 'guard let position = delimFound[kind], let headline = delimHeadline[kind],\n                  !headline.isEmpty, headline.count <= 48 else { continue }' 'guard let position = delimFound[kind], let headline = delimHeadline[kind],\n                  !headline.isEmpty else { continue }'
run_mutant m4b-headline-gate-drop
mutate "$SRC" 'if Self.isBytePrefix(stored, of: growing) {' 'if true {'
run_mutant m5-validation-drop
mutate "$SRC" '        guard !headSkip2Fixed else { return }' '        headSkip2 = 0; headSkip2Fixed = true; return'
run_mutant m6-headskip2-drop
mutate "$SRC" '        for kind in 0..<2 {' '        for kind in [1, 0] {'
run_mutant m7-kind-order-swap
mutate "$SRC" '                for marker in Self.markerBytes\n                where Self.isProperPrefix(in: buf, at: lead, limit: buf.count - trail, of: marker) {\n                    return -1\n                }' '                for marker in Self.markerBytes\n                where Self.isProperPrefix(in: buf, at: lead, limit: buf.count - trail, of: marker) {\n                    continue\n                }'
run_mutant m8-marker-premature
mutate "$SRC" 'zoneLen = trim ? zoneLen + need : 0' 'zoneLen = 0'
run_mutant m9-zone-drop-fullwidth
mutate "$SRC" 'let trail = Self.trailingRun(in: buf, limit: buf.count, from: machinePos, trimSet: false)\n            let feedLimit = buf.count - trail' 'let feedLimit = buf.count'
run_mutant m10-ws-holdback-drop
# Review-fix revert mutants (v6):
mutate "$SRC" 'var pos = max(delimScanPos, headSkip2)' 'var pos = delimScanPos'
run_mutant m11-revert-F1-delim-scan-from-zero
mutate "$SRC" 'if Self.isBytePrefix(stored, of: growing) {' 'if growing == stored || Self.isBytePrefix(stored, of: growing) {'
run_mutant m12-revert-F2-canonical-eq
mutate "$SRC" '        if buf[after] >= 0x80, String.beginsBindingMark(in: buf, at: after) { return false }\n        return true' '        return true'
run_mutant m13-revert-F3-marker-binding-blind
mutate "$SRC" 'isWhitespaceScalar(scalar) || scalar == 0x200B' 'isWhitespaceScalar(scalar)'
run_mutant m14-revert-F4-zwsp

cp "$OUT/pristine.swift" "$SRC"
git diff --stat
echo "=== battery-v2 done $(date) ==="
