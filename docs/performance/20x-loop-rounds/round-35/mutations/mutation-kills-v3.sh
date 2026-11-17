#!/bin/bash
# Round-35 v3 mutation battery: 9 mutants over the incremental-index
# mechanism + control. Documents the fail-safe equivalences (TV owner-base
# errors trip the anchored duplicate check -> whole-window fallback ->
# output-correct; TV identities no-subtract over-rejects -> whole-window
# fallback) vs the killable defects. Mutant 9 (no observed-term restore,
# the reviewer's finding) MUST die on the projection-level consumed-term
# differential (scenario 10D: separable flips).
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
MAIN=/home/<dev>/.t3/worktrees/perch/t3-b3eb4bba-c5db753ed6879e15
CAND=740b5f2e
OUT="$MAIN/.local/round35/mutations-v3"
MUT=/tmp/r35-mut
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

mut() { python3 - "$@"; }

# 1. TV owner base: no shift at all (expected: survives via anchored-check fail-safe)
python3 - <<'PYMUT'
p = 'Sources/WorkbenchCore/ToolVisibilityProjection.swift'
s = open(p).read()
old = 'ownerBase = cachedOwnerBase + alignment.lowerBound - consumedLeading'
assert s.count(old) == 1
open(p, 'w').write(s.replace(old, 'ownerBase = cachedOwnerBase'))
PYMUT
run_mutant tv-base-shift-removal

# 2. TV owner base: off-by-consumed (the merge-case bug class in TV)
python3 - <<'PYMUT'
p = 'Sources/WorkbenchCore/ToolVisibilityProjection.swift'
s = open(p).read()
old = 'ownerBase = cachedOwnerBase + alignment.lowerBound - consumedLeading'
assert s.count(old) == 1
open(p, 'w').write(s.replace(old, 'ownerBase = cachedOwnerBase + alignment.lowerBound'))
PYMUT
run_mutant tv-base-off-by-consumed

# 3. TV: skip consumed-identity removal (expected: survives via duplicate-rejection fail-safe)
python3 - <<'PYMUT'
p = 'Sources/WorkbenchCore/ToolVisibilityProjection.swift'
s = open(p).read()
old = '''            if let consumedIdentities {
                let consumedRelative = 0 - cachedOwnerBase
                for id in consumedIdentities where incremental[id] == consumedRelative {
                    incremental.removeValue(forKey: id)
                }
            }
'''
assert s.count(old) == 1
open(p, 'w').write(s.replace(old, ''))
PYMUT
run_mutant tv-consumed-removal-skip

# 4. TV: identities set skips consumed subtraction
python3 - <<'PYMUT'
p = 'Sources/WorkbenchCore/ToolVisibilityProjection.swift'
s = open(p).read()
old = '            if let consumedIdentities { set.subtract(consumedIdentities) }\n'
assert s.count(old) == 1
open(p, 'w').write(s.replace(old, ''))
PYMUT
run_mutant tv-identities-no-subtract

# 5. History base: no shift (known kill: PresentationHistoryTests)
python3 - <<'PYMUT'
p = 'Sources/WorkbenchCore/ConversationPresentation.swift'
s = open(p).read()
old = 'let base = prior.turnIndexBase + match.leadingNew - match.consumed'
assert s.count(old) == 1
open(p, 'w').write(s.replace(old, 'let base = prior.turnIndexBase'))
PYMUT
run_mutant history-base-shift-removal

# 6. History base: off-by-consumed (the actual v1 defect — must die on the
#    all-rows overlay pin at the merge step)
python3 - <<'PYMUT'
p = 'Sources/WorkbenchCore/ConversationPresentation.swift'
s = open(p).read()
old = 'let base = prior.turnIndexBase + match.leadingNew - match.consumed'
assert s.count(old) == 1
open(p, 'w').write(s.replace(old, 'let base = prior.turnIndexBase + match.leadingNew'))
PYMUT
run_mutant history-base-off-by-consumed

# 7. History: skip consumed-entry removal (stale mappings; widened overlay must kill)
python3 - <<'PYMUT'
p = 'Sources/WorkbenchCore/ConversationPresentation.swift'
s = open(p).read()
old = '''                if match.consumed > 0 {
                    // Drop the consumed leading turn's entries; the merged
                    // turn re-inserts the ids it still carries below.
                    let consumedRelative = 0 - prior.turnIndexBase
                    for row in prior.turns[0].rows where entryTurns[row.entry.id] == consumedRelative {
                        entryTurns.removeValue(forKey: row.entry.id)
                    }
                }
'''
assert s.count(old) == 1
open(p, 'w').write(s.replace(old, ''))
PYMUT
run_mutant history-consumed-removal-skip

# 8. History: weaken suffix check from instance identity to count-only
python3 - <<'PYMUT'
p = 'Sources/WorkbenchCore/ConversationPresentation.swift'
s = open(p).read()
old = 'if (0..<suffixCount).allSatisfy({ turns[k + $0] === prior.turns[consumed + $0] }) {'
assert s.count(old) == 1
open(p, 'w').write(s.replace(old, 'if (0..<suffixCount).allSatisfy({ _ in true }) {'))
PYMUT
run_mutant history-suffix-check-weakened

# 9. TV: incremental identities skips the observed-term restore (reviewer's
#    finding — MUST die on scenario 10D separable flip)
python3 - <<'PYMUT'
p = 'Sources/WorkbenchCore/ToolVisibilityProjection.swift'
s = open(p).read()
old = '''            // Restore the observed term: subtracting a consumed turn's chunk
            // identities can drop ids that the full build re-derives from
            // observed entries whose anchor differs from the current split
            // (review finding, round-35 v3).
            set.formUnion(observed.compactMap { $0.value.anchor != anchor ? $0.key : nil })
'''
assert s.count(old) == 1
open(p, 'w').write(s.replace(old, ''))
PYMUT
run_mutant tv-identities-no-restore

echo "=== control rerun (tree restored) $(date) ==="
swift build -c release --product WorkbenchChecks > "$OUT/control-rebuild.log" 2>&1
echo "control_rebuild_exit=$?"
"$MUT/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks" > "$OUT/control-rerun-checks.log" 2>&1
echo "control_rerun_exit=$? pass=$(grep -c '^PASS' "$OUT/control-rerun-checks.log")"
cd "$MAIN"
git worktree remove --force "$MUT" 2>/dev/null
echo "DONE $(date)"
