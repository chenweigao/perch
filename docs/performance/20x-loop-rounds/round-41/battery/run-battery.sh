#!/bin/bash
# Round-41 mutation battery: each mutant must DIE (nonzero WorkbenchChecks
# exit) under checkCommentaryDerivation or another pin. Runs on Linux debug
# builds; records killer line per mutant. Tree must be at the candidate
# commit with a clean porcelain (Sources/Tests).
set -u
cd /home/<dev>/.t3/worktrees/perch/t3-b3eb4bba-c5db753ed6879e15
export PATH=/home/<dev>/.local/swift/6.3.3/usr/bin:$PATH
SRC=Sources/WorkbenchCore/ActivityNarrative.swift
OUT=.local/round41/battery
mkdir -p "$OUT"
cp "$SRC" "$OUT/pristine.swift"

run_mutant() {
  local name="$1"
  swift build --product WorkbenchChecks > "$OUT/$name-build.log" 2>&1
  local bexit=$?
  if [ $bexit != 0 ]; then echo "$name BUILD-FAIL (mutant does not compile — fix patch)"; cp "$OUT/pristine.swift" "$SRC"; return; fi
  timeout 1200 .build/debug/WorkbenchChecks > "$OUT/$name.log" 2>&1
  local exit=$?
  local killer
  killer=$(grep -m1 -E "Precondition failed|Fatal|error:" "$OUT/$name.log" | head -1)
  if [ $exit != 0 ]; then
    echo "$name DIED exit=$exit killer=$killer"
  else
    echo "$name SURVIVED (exit=0) — PIN GAP"
  fi
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

echo "=== battery start $(date) ==="

# M0: pristine control — must pass.
cp "$OUT/pristine.swift" "$SRC"
swift build --product WorkbenchChecks > "$OUT/m0-build.log" 2>&1
.build/debug/WorkbenchChecks > "$OUT/m0-pristine.log" 2>&1
echo "m0-pristine exit=$? (must be 0)"

# M1: headTrim-drop — leading trim scalars no longer dropped.
mutate "$SRC" 'if Self.isTrimScalar(value) { headPending = []; return }' 'if false && Self.isTrimScalar(value) { headPending = []; return }'
run_mutant m1-headtrim-drop

# M2: zone-drop — trailing trim zone never tracked (leaks into trimmed view).
mutate "$SRC" 'zoneLen = Self.isTrimScalar(UInt32(byte)) ? zoneLen + 1 : 0' 'zoneLen = 0'
run_mutant m2-zone-drop-ascii

# M3: phase tail-replay drop — resolve from committed state only.
mutate "$SRC" 'NarrativePhaseScan.scan(&tail, buf, limit: lenTrimmed, count: lenTrimmed)' 'NarrativePhaseScan.scan(&tail, buf, limit: phaseState.offset, count: lenTrimmed)'
run_mutant m3-phase-tail-drop

# M4: gate freeze — commit first found kind regardless of detail nonempty.
mutate "$SRC" 'if nonEmpty { chosen = (kind, start); break }' 'chosen = (kind, start); break'
run_mutant m4-gate-freeze

# M5: validation drop — every changed part treated as prefix growth.
mutate "$SRC" '(Self.isBytePrefix(stored, of: growing) ? .growth : .reseed)' '(true ? .growth : .reseed)'
run_mutant m5-validation-drop

# M6: headSkip2 drop — clean(text) head marker/trim skip forced to zero.
mutate "$SRC" '        guard !headSkip2Fixed else { return }' '        headSkip2 = 0; headSkip2Fixed = true; return'
run_mutant m6-headskip2-drop

# M7: kind priority swap — ": " evaluated before fullwidth colon.
mutate "$SRC" '        for kind in 0..<2 {' '        for kind in [1, 0] {'
run_mutant m7-kind-order-swap

# M8: marker premature commit — undetermined head treated as resolved-none.
mutate "$SRC" '''                for marker in Self.markerBytes
                where Self.isProperPrefix(in: buf, at: lead, limit: buf.count - trail, of: marker) {
                    return -1
                }''' '                _ = Self.isProperPrefix'
run_mutant m8-marker-premature

# M9: zone-drop multibyte — fullwidth colon never joins the trailing zone.
mutate "$SRC" 'zoneLen = trim ? zoneLen + need : 0' 'zoneLen = 0'
run_mutant m9-zone-drop-fullwidth

# M10: trailing-ws holdback drop — non-ASCII trailing ws feeds the machine.
mutate "$SRC" 'let trail = Self.trailingRun(in: buf, limit: buf.count, from: machinePos, trimSet: false)\n            let feedLimit = buf.count - trail' 'let feedLimit = buf.count'
run_mutant m10-ws-holdback-drop

cp "$OUT/pristine.swift" "$SRC"
git diff --stat
echo "=== battery done $(date) ==="
