#!/bin/bash
# Round-36 v2 mutation battery: 6 mutants over the joined foldParents
# adoption mechanism + control. Expected kills: consumed-removal-skip and
# wrong-order (merge scenario foldParents), gate-activity-removal (scenario
# 11, pre-verified exit 132), dropFirst-count-skip (merge rows duplicate),
# leading-insert-skip (foldParents missing on first prepend). Expected
# documented survivor: prior-uniqueEntries-gate-removal — STRUCTURALLY
# UNREACHABLE: duplicate entry ids poison the chunk path at the TV level
# (scenario 9 family) before any History with prior.uniqueEntries=false can
# reach an alignment capture, so the gate is defense-in-depth.
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
MAIN=/home/<dev>/.t3/worktrees/perch/t3-b3eb4bba-c5db753ed6879e15
CAND=0c42b7d3
OUT="$MAIN/.local/round36/mutations-r36v2"
MUT=/tmp/r36-mut
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
  if [ "$build_exit" != 0 ]; then echo "$name BUILD_FAIL"; tail -3 "$OUT/$name-build.log"; git checkout -- Sources/ Tests/; return; fi
  timeout 900 "$MUT/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks" > "$OUT/$name-checks.log" 2>&1
  exit_code=$?
  kill_at=$(grep -a -A8 'crashed:' "$OUT/$name-checks.log" | grep -m1 -oE '[A-Za-z]+\.swift:[0-9]+' || echo '?')
  pass=$(grep -c '^PASS' "$OUT/$name-checks.log")
  echo "$name exit=$exit_code pass=$pass kill_at=$kill_at"
  git checkout -- Sources/ Tests/
}

echo "=== control $(date) ==="
swift build -c release --product WorkbenchChecks > "$OUT/control-build.log" 2>&1
echo "control_build_exit=$?"
"$MUT/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks" > "$OUT/control-checks.log" 2>&1
echo "control_exit=$? pass=$(grep -c '^PASS' "$OUT/control-checks.log")"

# 1. skip consumed fold-key removal (stale consumed keys survive in parents)
python3 - <<'PYMUT'
p = 'Sources/WorkbenchCore/ConversationPresentation.swift'
s = open(p).read()
old = '            for key in adoption.consumedFoldKeys { parents.removeValue(forKey: key) }\n'
assert s.count(old) == 1
open(p, 'w').write(s.replace(old, ''))
PYMUT
run_mutant joined-consumed-removal-skip

# 2. wrong order: insert leading BEFORE removing consumed (merge re-carried
#    ids get deleted after reinsertion)
python3 - <<'PYMUT'
p = 'Sources/WorkbenchCore/ConversationPresentation.swift'
s = open(p).read()
old = '''            var parents = adoption.foldParents  // COW copy on first mutation; no rehash
            for key in adoption.consumedFoldKeys { parents.removeValue(forKey: key) }
            for (key, parent) in leadingParents { parents[key] = parent }'''
new = '''            var parents = adoption.foldParents  // COW copy on first mutation; no rehash
            for (key, parent) in leadingParents { parents[key] = parent }
            for key in adoption.consumedFoldKeys { parents.removeValue(forKey: key) }'''
assert s.count(old) == 1
open(p, 'w').write(s.replace(old, new))
PYMUT
run_mutant joined-wrong-order

# 3. capture gate ignores the prior memo's activity (pre-verified: dies on
#    scenario 11 overlay-last)
python3 - <<'PYMUT'
p = 'Sources/WorkbenchCore/ConversationPresentation.swift'
s = open(p).read()
old = 'if prior.uniqueEntries, let priorMemo = prior.presentation, priorMemo.activity.isEmpty {'
assert s.count(old) == 1
open(p, 'w').write(s.replace(old, 'if prior.uniqueEntries, let priorMemo = prior.presentation {'))
PYMUT
run_mutant joined-gate-activity-removal

# 4. rows adoption skips the consumed-row dropFirst (duplicate rows)
python3 - <<'PYMUT'
p = 'Sources/WorkbenchCore/ConversationPresentation.swift'
s = open(p).read()
old = 'rows.append(contentsOf: adoption.rows.dropFirst(adoption.consumedRowCount))'
assert s.count(old) == 1
open(p, 'w').write(s.replace(old, 'rows.append(contentsOf: adoption.rows)'))
PYMUT
run_mutant joined-dropfirst-count-skip

# 5. skip leading foldParents insertion (leading folds missing)
python3 - <<'PYMUT'
p = 'Sources/WorkbenchCore/ConversationPresentation.swift'
s = open(p).read()
old = '            for (key, parent) in leadingParents { parents[key] = parent }\n'
assert s.count(old) == 1
open(p, 'w').write(s.replace(old, ''))
PYMUT
run_mutant joined-leading-insert-skip

# 6. capture gate drops prior.uniqueEntries (expected survivor: structurally
#    unreachable — duplicate-entry windows poison the chunk path first)
python3 - <<'PYMUT'
p = 'Sources/WorkbenchCore/ConversationPresentation.swift'
s = open(p).read()
old = 'if prior.uniqueEntries, let priorMemo = prior.presentation, priorMemo.activity.isEmpty {'
assert s.count(old) == 1
open(p, 'w').write(s.replace(old, 'if let priorMemo = prior.presentation, priorMemo.activity.isEmpty {'))
PYMUT
run_mutant joined-prior-unique-gate-removal

echo "=== control rerun (tree restored) $(date) ==="
swift build -c release --product WorkbenchChecks > "$OUT/control-rebuild.log" 2>&1
echo "control_rebuild_exit=$?"
"$MUT/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks" > "$OUT/control-rerun-checks.log" 2>&1
echo "control_rerun_exit=$? pass=$(grep -c '^PASS' "$OUT/control-rerun-checks.log")"
cd "$MAIN"
git worktree remove --force "$MUT" 2>/dev/null
echo "DONE $(date)"
