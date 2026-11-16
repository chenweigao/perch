#!/bin/bash
# Round-30 mutation red-runs: every mutant must DIE (non-zero exit) against the
# new pin set. Build failures do not count as kills.
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
MAIN=<worktree>
OUT=$MAIN/.local/round30/mutations-v5
rm -rf "$OUT"; mkdir -p "$OUT"
git -C "$MAIN" worktree remove --force /tmp/r30v5-mut >/dev/null 2>&1; rm -rf /tmp/r30v5-mut; git -C "$MAIN" worktree prune
git -C "$MAIN" worktree add --detach /tmp/r30v5-mut ded7625 >/dev/null 2>&1 || { echo WORKTREE_FAIL; exit 1; }
cd /tmp/r30v5-mut
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
# 3. zero accounting
cat > /tmp/m30-acct.py <<'PY'
p = 'Sources/WorkbenchCore/ConversationEntryCache.swift'
s = open(p).read()
a = '        estimatedBytes += cost'
assert s.count(a) == 1
s = s.replace(a, '        estimatedBytes += 0')
open(p, 'w').write(s)
PY
run_mutant zero-accounting /tmp/m30-acct.py
# 4. reverse LRU
cat > /tmp/m30-lru.py <<'PY'
p = 'Sources/WorkbenchCore/ConversationEntryCache.swift'
s = open(p).read()
a = 'let ordered = table.sorted { $0.value.lastUse < $1.value.lastUse }'
assert s.count(a) == 1
s = s.replace(a, 'let ordered = table.sorted { $0.value.lastUse > $1.value.lastUse }')
open(p, 'w').write(s)
PY
run_mutant reverse-lru /tmp/m30-lru.py
# 5. admit oversized
cat > /tmp/m30-oversize.py <<'PY'
p = 'Sources/WorkbenchCore/ConversationEntryCache.swift'
s = open(p).read()
a = '        guard cost <= byteBudget else { return }'
assert s.count(a) == 1
s = s.replace(a, '        // MUTANT: oversize admitted')
open(p, 'w').write(s)
PY
run_mutant admit-oversized /tmp/m30-oversize.py
# 6. no locale observer
cat > /tmp/m30-locale.py <<'PY'
p = 'Sources/WorkbenchCore/ConversationEntryCache.swift'
s = open(p).read()
a = '''        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.generation += 1
            self.table.removeAll()
            self.estimatedBytes = 0
            self.lock.unlock()
        }'''
assert s.count(a) == 1
s = s.replace(a, '        localeObserver = nil')
open(p, 'w').write(s)
PY
run_mutant no-locale-observer /tmp/m30-locale.py
# 7. NUL-collision key (v1 zero-separator encoding)
cat > /tmp/m30v2-nulkey.py <<'PY'
p = 'Sources/WorkbenchCore/ConversationEntryCache.swift'
s = open(p).read()
a = """        var bytes: [UInt8] = []
        appendLengthPrefixed(&bytes, entryID)
        appendLengthPrefixed(&bytes, query)"""
assert s.count(a) == 1
s = s.replace(a, """        var bytes: [UInt8] = []
        bytes.append(contentsOf: entryID.utf8)
        bytes.append(0)
        bytes.append(contentsOf: query.utf8)
        bytes.append(0)""")
open(p, 'w').write(s)
PY
run_mutant nul-collision-key /tmp/m30v2-nulkey.py
# 8. key-cost-exclusion (v1 admission cost = payload only)
cat > /tmp/m30v2-keycost.py <<'PY'
p = 'Sources/WorkbenchCore/ConversationEntryCache.swift'
s = open(p).read()
a = '        estimatedCost(of: payload) + keyBytes.count + payload.query.utf8.count'
assert s.count(a) == 1
s = s.replace(a, '        estimatedCost(of: payload)')
open(p, 'w').write(s)
PY
run_mutant key-cost-exclusion /tmp/m30v2-keycost.py
# 9. no-generation-guard (v1 store: drop the generation check)
cat > /tmp/m30v2-nogen.py <<'PY'
p = 'Sources/WorkbenchCore/ConversationEntryCache.swift'
s = open(p).read()
a = '        guard generation == builtAt else { return }'
assert s.count(a) == 1
s = s.replace(a, '        _ = builtAt')
open(p, 'w').write(s)
PY
run_mutant no-generation-guard /tmp/m30v2-nogen.py
# 10. payload-fields-exclusion (v4 cost formula: no JSONValue walk)
cat > /tmp/m30v5-fields.py <<'PY'
p = 'Sources/WorkbenchCore/ConversationEntryCache.swift'
s = open(p).read()
a = '            if let metadata = message.metadata { cost += jsonValueSize(metadata) }'
assert s.count(a) == 1
s = s.replace(a, '            _ = message.metadata')
b2 = '                if let input = part.input { cost += jsonValueSize(input) }'
assert s.count(b2) == 1
s = s.replace(b2, '                _ = part.input')
c2 = '                if let output = part.output { cost += jsonValueSize(output) }'
assert s.count(c2) == 1
s = s.replace(c2, '                _ = part.output')
d2 = '                if let source = part.source { cost += jsonValueSize(source) }'
assert s.count(d2) == 1
s = s.replace(d2, '                _ = part.source')
open(p, 'w').write(s)
PY
run_mutant payload-fields-exclusion /tmp/m30v5-fields.py
git checkout -- Sources/ Tests/
cd "$MAIN"
git worktree remove --force /tmp/r30v5-mut
cat "$OUT/receipt.txt"
echo "DONE $(date)"
