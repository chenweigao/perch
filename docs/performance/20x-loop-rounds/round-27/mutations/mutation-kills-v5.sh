#!/bin/bash
# Round-27 v5 mutation red-runs: the review recheck's NFC-normalization mutants
# (survived v3's canonical == assertions) must DIE on v5's byte-level assertions.
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
MAIN=<worktree>
OUT=$MAIN/.local/round27/mutations
git -C "$MAIN" worktree remove --force /tmp/r27-mut5 >/dev/null 2>&1; rm -rf /tmp/r27-mut5; git -C "$MAIN" worktree prune
git -C "$MAIN" worktree add --detach /tmp/r27-mut5 "$1" >/dev/null 2>&1 || { echo WORKTREE_FAIL; exit 1; }
cd /tmp/r27-mut5
BIN=.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks
run_mutant() {
  name="$1"; shift
  git checkout -- Sources/ Tests/
  python3 "$@" || { echo "$name MUTATE_FAIL"; echo "$name mutate_fail" >> "$OUT/receipt-v5.txt"; return; }
  swift build -c release --product WorkbenchChecks > "$OUT/$name-build.log" 2>&1
  bexit=$?
  if [ "$bexit" != 0 ]; then echo "$name BUILD_FAIL (not a kill)"; echo "$name build_fail" >> "$OUT/receipt-v5.txt"; return; fi
  timeout 600 "$BIN" > "$OUT/$name-run.log" 2>&1
  rexit=$?
  echo "$name exit=$rexit"
  echo "$name exit=$rexit" >> "$OUT/receipt-v5.txt"
}
cat > /tmp/mut-norm-hit.py <<'PY'
p = 'Sources/WorkbenchCore/RenderedSourceCache.swift'
s = open(p).read()
a = '            return node.rendered'
assert s.count(a) == 1
s = s.replace(a, '            return node.rendered.precomposedStringWithCanonicalMapping')
open(p, 'w').write(s)
PY
run_mutant normalize-cache-hit-nfc /tmp/mut-norm-hit.py
cat > /tmp/mut-norm-render.py <<'PY'
p = 'Sources/WorkbenchCore/RenderedSourceCache.swift'
s = open(p).read()
a = '        let produced = produce()'
assert s.count(a) == 1
s = s.replace(a, '        let produced = produce().precomposedStringWithCanonicalMapping')
open(p, 'w').write(s)
PY
run_mutant normalize-render-nfc /tmp/mut-norm-render.py
git checkout -- Sources/ Tests/
cd "$MAIN"
git worktree remove --force /tmp/r27-mut5
cat "$OUT/receipt-v5.txt"
echo "DONE $(date)"
