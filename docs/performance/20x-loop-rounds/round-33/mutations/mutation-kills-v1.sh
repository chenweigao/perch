#!/bin/bash
# Round-33 v1 DELTA mutation battery: the concat guard is the only product
# change vs round-32 v3 (whose full 17-mutant battery is on record at
# ec3111e), so this battery covers the new surface: remove-guard, the
# over-application mutant (always skip concat), and control. Runs in an
# isolated worktree — NEVER while Linux A/B timing pairs are running.
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
MAIN=<worktree>
CAND=afd99aa
OUT="$MAIN/.local/round33/mutations-v1"
MUT=/tmp/r33-mut
mkdir -p "$OUT"
cd "$MAIN"
git worktree remove --force "$MUT" 2>/dev/null
rm -rf "$MUT"
git worktree add --detach "$MUT" "$CAND" >/dev/null 2>&1
cd "$MUT"

run_mutant() {
  name="$1"
  swift build -c release --product WorkbenchChecks > "$OUT/$name-build.log" 2>&1
  build_exit=$?
  if [ "$build_exit" != 0 ]; then echo "$name BUILD_FAIL"; tail -5 "$OUT/$name-build.log"; git checkout -- Sources/ Tests/; return; fi
  timeout 900 "$MUT/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks" > "$OUT/$name-checks.log" 2>&1
  exit_code=$?
  kill_at=$(grep -a -A8 'crashed:' "$OUT/$name-checks.log" | grep -m1 -oE '[A-Za-z]+\.swift:[0-9]+' || echo '?')
  echo "$name exit=$exit_code kill_at=$kill_at"
  git checkout -- Sources/ Tests/
}

echo "=== control $(date) ==="
swift build -c release --product WorkbenchChecks > "$OUT/control-build.log" 2>&1
echo "control_build_exit=$?"
"$MUT/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks" > "$OUT/control-checks.log" 2>&1
echo "control_exit=$? pass=$(grep -c '^PASS' "$OUT/control-checks.log")"

# 1. remove-concat-guard: restore the unconditional += (v3 shape)
python3 - <<'EOF'
p = 'Sources/WorkbenchCore/ConversationSearch.swift'
s = open(p).read()
old = '''        if !suffixHits.isEmpty {
            hits += suffixHits
        }'''
assert old in s
open(p, 'w').write(s.replace(old, '        hits += suffixHits'))
EOF
run_mutant remove-concat-guard

# 2. always-skip-concat: over-applied guard (never concatenates)
python3 - <<'EOF'
p = 'Sources/WorkbenchCore/ConversationSearch.swift'
s = open(p).read()
old = '''        if !suffixHits.isEmpty {
            hits += suffixHits
        }'''
assert old in s
open(p, 'w').write(s.replace(old, '''        if !suffixHits.isEmpty, false {
            hits += suffixHits
        }'''))
EOF
run_mutant always-skip-concat

echo "=== control rerun (tree restored) $(date) ==="
swift build -c release --product WorkbenchChecks > "$OUT/control-rebuild.log" 2>&1
echo "control_rebuild_exit=$?"
"$MUT/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks" > "$OUT/control-rerun-checks.log" 2>&1
echo "control_rerun_exit=$? pass=$(grep -c '^PASS' "$OUT/control-rerun-checks.log")"
cd "$MAIN"
git worktree remove --force "$MUT" 2>/dev/null
echo "DONE $(date)"
