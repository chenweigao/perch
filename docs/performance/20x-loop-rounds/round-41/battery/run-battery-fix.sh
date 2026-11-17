#!/bin/bash
set -u
cd /home/<dev>/.t3/worktrees/perch/t3-b3eb4bba-c5db753ed6879e15
export PATH=/home/<dev>/.local/swift/6.3.3/usr/bin:$PATH
SRC=Sources/WorkbenchCore/ActivityNarrative.swift
OUT=.local/round41/battery
cp "$SRC" "$OUT/pristine.swift"

run_mutant() {
  local name="$1"
  swift build --product WorkbenchChecks > "$OUT/$name-build.log" 2>&1
  local bexit=$?
  if [ $bexit != 0 ]; then echo "$name BUILD-FAIL"; grep -m2 "error:" "$OUT/$name-build.log"; cp "$OUT/pristine.swift" "$SRC"; return; fi
  timeout 1200 .build/debug/WorkbenchChecks > "$OUT/$name.log" 2>&1
  local exit=$?
  local killer
  killer=$(grep -m1 -E "Precondition failed|Fatal|error:" "$OUT/$name.log" | head -1)
  if [ $exit != 0 ]; then echo "$name DIED exit=$exit killer=$killer"
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
echo "=== battery-fix start $(date) ==="
# M4': headline-48 gate drop (the nonEmpty half of the old M4 is an
# equivalent mutant: a committed delimiter always leaves a non-trim byte
# below lenTrimmed, so detail is structurally nonempty).
mutate "$SRC" 'guard let position = delimFound[kind], let headline = delimHeadline[kind],\n                  !headline.isEmpty, headline.count <= 48 else { continue }' 'guard let position = delimFound[kind], let headline = delimHeadline[kind],\n                  !headline.isEmpty else { continue }'
run_mutant m4b-headline-gate-drop
# M8': marker premature commit — proper-prefix undetermined branch neutered.
mutate "$SRC" '                for marker in Self.markerBytes\n                where Self.isProperPrefix(in: buf, at: lead, limit: buf.count - trail, of: marker) {\n                    return -1\n                }' '                for marker in Self.markerBytes\n                where Self.isProperPrefix(in: buf, at: lead, limit: buf.count - trail, of: marker) {\n                    continue\n                }'
run_mutant m8-marker-premature
# M9: fullwidth colon never joins the trailing zone.
mutate "$SRC" 'zoneLen = trim ? zoneLen + need : 0' 'zoneLen = 0'
run_mutant m9-zone-drop-fullwidth
# M10: trailing whitespace holdback dropped.
mutate "$SRC" 'let trail = Self.trailingRun(in: buf, limit: buf.count, from: machinePos, trimSet: false)\n            let feedLimit = buf.count - trail' 'let feedLimit = buf.count'
run_mutant m10-ws-holdback-drop
cp "$OUT/pristine.swift" "$SRC"
git diff --stat
echo "=== battery-fix done $(date) ==="
