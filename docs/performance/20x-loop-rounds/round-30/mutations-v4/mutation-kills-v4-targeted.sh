#!/bin/bash
# Round-30 mutation red-runs: every mutant must DIE (non-zero exit) against the
# new pin set. Build failures do not count as kills.
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
MAIN=<worktree>
OUT=$MAIN/.local/round30/mutations-v4
rm -rf "$OUT"; mkdir -p "$OUT"
git -C "$MAIN" worktree remove --force /tmp/r30v4-mut >/dev/null 2>&1; rm -rf /tmp/r30v4-mut; git -C "$MAIN" worktree prune
git -C "$MAIN" worktree add --detach /tmp/r30v4-mut HEAD >/dev/null 2>&1 || { echo WORKTREE_FAIL; exit 1; }
cd /tmp/r30v4-mut
BIN=.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks
run_mutant() {
  name="$1"; shift
  git checkout -- Sources/ Tests/
  python3 "$@" || { echo "$name MUTATE_FAIL"; echo "$name mutate_fail" >> "$OUT/receipt.txt"; return; }
  swift build -c release --product WorkbenchChecks > "$OUT/$name-build.log" 2>&1
  if [ $? != 0 ]; then echo "$name BUILD_FAIL (not a kill)"; echo "$name build_fail" >> "$OUT/receipt.txt"; return; fi
  timeout 600 "$BIN" > "$OUT/$name-run.log" 2>&1
  rexit=$?
  loc=$(grep -A5 'crashed:' "$OUT/$name-run.log" | grep -m1 -oE '[A-Za-z]+\.swift:[0-9]+' || echo '?')
  echo "$name exit=$rexit kill_at=$loc"
  echo "$name exit=$rexit kill_at=$loc" >> "$OUT/receipt.txt"
}
# 1. skip verification (always reuse)
cat > /tmp/m30-noverify.py <<'PY'
p = 'Sources/WorkbenchCore/ConversationEntryCache.swift'
s = open(p).read()
a = '''        guard KimiMessage.sameSearchableWindow(messages, node.payload.messages[...]) else {
            return nil
        }'''
assert s.count(a) == 1
s = s.replace(a, '        // MUTANT: verification skipped')
open(p, 'w').write(s)
PY
run_mutant skip-verification /tmp/m30-noverify.py
# 2. canonical String key
cat > /tmp/m30-strkey.py <<'PY'
p = 'Sources/WorkbenchCore/ConversationEntryCache.swift'
s = open(p).read()
a = '''    private struct Key: Hashable {
        let bytes: [UInt8]
        func hash(into hasher: inout Hasher) {
            bytes.withUnsafeBufferPointer { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        }
        static func == (lhs: Key, rhs: Key) -> Bool { lhs.bytes == rhs.bytes }
    }'''
assert s.count(a) == 1
s = s.replace(a, '''    private struct Key: Hashable {
        let bytes: [UInt8]
        private var canonical: String { String(decoding: bytes, as: UTF8.self) }
        func hash(into hasher: inout Hasher) { hasher.combine(canonical) }
        static func == (lhs: Key, rhs: Key) -> Bool { lhs.canonical == rhs.canonical }
    }''')
open(p, 'w').write(s)
PY
run_mutant canonical-string-key /tmp/m30-strkey.py
# control: unmutated tree must pass
git checkout -- Sources/ Tests/
swift build -c release --product WorkbenchChecks > "$OUT/control-build.log" 2>&1
if [ $? = 0 ]; then timeout 600 "$BIN" > "$OUT/control-run.log" 2>&1; echo "control exit=$?" | tee -a "$OUT/receipt.txt"; fi
git checkout -- Sources/ Tests/
cd "$MAIN"
git worktree remove --force /tmp/r30v4-mut
cat "$OUT/receipt.txt"
echo "DONE $(date)"
