#!/bin/bash
# Round-38 v3 mutation battery: 5 mutants over the tool-resolution memo +
# control (CAND=a867c35f, includes the review-F1 language token). Expected
# kills: no-validation (pre-verified exit=132), status-only-validation
# (input change step). Expected documented survivors: eviction-removal
# (retention-only), key-by-name (full-value validation rescues: output
# equivalent, cache-thrash only), language-token-drop (PLATFORM-LIMITED
# EQUIVALENCE on Linux: L() is identity off-Darwin so stale-language
# resolutions are output-identical there; the defect and its pin leg are
# Darwin-observable — recorded honestly, not a pin gap on the platform
# that exhibits the behavior).
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
MAIN=/home/<dev>/.t3/worktrees/perch/t3-b3eb4bba-c5db753ed6879e15
CAND=a867c35f
OUT="$MAIN/.local/round38/mutations-r38v3"
MUT=/tmp/r38-mut
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

# 1. no validation: always reuse the stored resolution (pre-verified killer)
python3 - <<'PYMUT'
p = 'Sources/WorkbenchCore/ActivityNarrative.swift'
s = open(p).read()
old = '        if let hit = toolResolutions[tool.id], hit.tool == tool, hit.language == language {'
assert s.count(old) == 1
open(p, 'w').write(s.replace(old, '        if let hit = toolResolutions[tool.id] {'))
PYMUT
run_mutant resolution-no-validation

# 2. status-only validation (misses input/output/progress moves)
python3 - <<'PYMUT'
p = 'Sources/WorkbenchCore/ActivityNarrative.swift'
s = open(p).read()
old = '        if let hit = toolResolutions[tool.id], hit.tool == tool, hit.language == language {'
assert s.count(old) == 1
open(p, 'w').write(s.replace(old, '        if let hit = toolResolutions[tool.id], hit.tool.status == tool.status, hit.language == language {'))
PYMUT
run_mutant resolution-status-only-validation

# 3. eviction cap removal (retention-only; output-equivalent -> expected survivor)
python3 - <<'PYMUT'
p = 'Sources/WorkbenchCore/ActivityNarrative.swift'
s = open(p).read()
old = '    if toolResolutions.count > 65536 { toolResolutions.removeAll() }\n'
assert s.count(old) == 1
open(p, 'w').write(s.replace(old, ''))
PYMUT
run_mutant resolution-eviction-removal

# 4. key memo by tool NAME instead of id (cross-tool contamination when a
#    turn holds two same-name tools with different inputs)
python3 - <<'PYMUT'
p = 'Sources/WorkbenchCore/ActivityNarrative.swift'
s = open(p).read()
old = '''        if let hit = toolResolutions[tool.id], hit.tool == tool, hit.language == language {'''
new = '''        if let hit = toolResolutions[tool.name], hit.tool == tool, hit.language == language {'''
assert s.count(old) == 1
s = s.replace(old, new)
old2 = '''        toolResolutions[tool.id] = (tool, language, derived)'''
new2 = '''        toolResolutions[tool.name] = (tool, language, derived)'''
assert s.count(old2) == 1
open(p, 'w').write(s.replace(old2, new2))
PYMUT
run_mutant resolution-key-by-name

# 5. language token drop (review F1 mutant — expected SURVIVAL on Linux:
#    L() identity makes stale-language resolutions output-equivalent there;
#    Darwin-observable defect class, documented platform-limited equivalence)
python3 - <<'PYMUT'
p = 'Sources/WorkbenchCore/ActivityNarrative.swift'
s = open(p).read()
old = 'if let hit = toolResolutions[tool.id], hit.tool == tool, hit.language == language {'
assert s.count(old) == 1
open(p, 'w').write(s.replace(old, 'if let hit = toolResolutions[tool.id], hit.tool == tool {'))
PYMUT
run_mutant resolution-language-token-drop

echo "=== control rerun (tree restored) $(date) ==="
swift build -c release --product WorkbenchChecks > "$OUT/control-rebuild.log" 2>&1
echo "control_rebuild_exit=$?"
"$MUT/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks" > "$OUT/control-rerun-checks.log" 2>&1
echo "control_rerun_exit=$? pass=$(grep -c '^PASS' "$OUT/control-rerun-checks.log")"
cd "$MAIN"
git worktree remove --force "$MUT" 2>/dev/null
echo "DONE $(date)"
