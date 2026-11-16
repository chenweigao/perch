#!/bin/bash
# Round-27 v3 pin mutation red-runs (review F1/F2 closure): every mutant must
# DIE (non-zero exit, precondition trap) against the v3 pin. Build failures do
# not count as kills and are flagged.
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
MAIN=<worktree>
OUT=$MAIN/.local/round27/mutations
rm -rf "$OUT"; mkdir -p "$OUT"
git -C "$MAIN" worktree remove --force /tmp/r27-mut >/dev/null 2>&1; rm -rf /tmp/r27-mut; git -C "$MAIN" worktree prune
git -C "$MAIN" worktree add --detach /tmp/r27-mut 28b3cb6 >/dev/null 2>&1 || { echo WORKTREE_FAIL; exit 1; }
cd /tmp/r27-mut
BIN=.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks

run_mutant() {
  name="$1"; shift
  git checkout -- Sources/ Tests/
  python3 "$@" || { echo "$name MUTATE_FAIL"; echo "$name mutate_fail" >> "$OUT/receipt.txt"; return; }
  swift build -c release --product WorkbenchChecks > "$OUT/$name-build.log" 2>&1
  bexit=$?
  if [ "$bexit" != 0 ]; then echo "$name BUILD_FAIL (not a kill)"; echo "$name build_fail" >> "$OUT/receipt.txt"; return; fi
  timeout 600 "$BIN" > "$OUT/$name-run.log" 2>&1
  rexit=$?
  lastline=$(grep -E 'rendered-source cache|Expected|Fatal' "$OUT/$name-run.log" | tail -1 | cut -c1-160)
  echo "$name exit=$rexit | $lastline"
  echo "$name exit=$rexit | $lastline" >> "$OUT/receipt.txt"
}

# 1. drop-duplicate (review F1 mutant, reviewer's exact construction)
cat > /tmp/mut-dup.py <<'PY'
p = 'Sources/WorkbenchCore/ConversationSearch.swift'
s = open(p).read()
a = '    private var entries: [String: Entry] = [:]'
assert s.count(a) == 1
s = s.replace(a, a + '\n    private var seenSourceBytes: Set<[UInt8]> = []')
b = '        guard !query.isEmpty else { return .empty }'
assert s.count(b) == 1
s = s.replace(b, b + '\n        seenSourceBytes.removeAll()')
c = '''                let rendered = sources.map { source in
                    renderedCache.rendered(source) { Self.renderedText(ReplyDocument.parse(source)) }
                }'''
assert s.count(c) == 1
s = s.replace(c, '''                let rendered = sources.map { source -> String in
                    guard seenSourceBytes.insert(Array(source.utf8)).inserted else { return "" }
                    return renderedCache.rendered(source) { Self.renderedText(ReplyDocument.parse(source)) }
                }''')
open(p, 'w').write(s)
PY
run_mutant drop-duplicate /tmp/mut-dup.py

# 2. reverse-lru (review F2 survivor on v2)
cat > /tmp/mut-lru.py <<'PY'
p = 'Sources/WorkbenchCore/RenderedSourceCache.swift'
s = open(p).read()
a = 'let ordered = table.sorted { $0.value.lastUse < $1.value.lastUse }'
assert s.count(a) == 1
s = s.replace(a, 'let ordered = table.sorted { $0.value.lastUse > $1.value.lastUse }')
open(p, 'w').write(s)
PY
run_mutant reverse-lru /tmp/mut-lru.py

# 3. zero-accounting (review F2 survivor on v2)
cat > /tmp/mut-acct.py <<'PY'
p = 'Sources/WorkbenchCore/RenderedSourceCache.swift'
s = open(p).read()
a = '            estimatedBytes += cost'
assert s.count(a) == 1
s = s.replace(a, '            estimatedBytes += 0')
open(p, 'w').write(s)
PY
run_mutant zero-accounting /tmp/mut-acct.py

# 4. admit-oversized (review F2 survivor on v2: insert then evict)
cat > /tmp/mut-oversize.py <<'PY'
p = 'Sources/WorkbenchCore/RenderedSourceCache.swift'
s = open(p).read()
a = '        if cost <= byteBudget {'
assert s.count(a) == 1
s = s.replace(a, '        if true {')
open(p, 'w').write(s)
PY
run_mutant admit-oversized /tmp/mut-oversize.py

# 5. no-locale-observer
cat > /tmp/mut-locale.py <<'PY'
p = 'Sources/WorkbenchCore/RenderedSourceCache.swift'
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
run_mutant no-locale-observer /tmp/mut-locale.py

# 6. string-key (canonical-equality keys; killed v1 pin, re-verify on v3)
cat > /tmp/mut-strkey.py <<'PY'
p = 'Sources/WorkbenchCore/RenderedSourceCache.swift'
s = open(p).read()
a = 'private var table: [[UInt8]: Node] = [:]'
assert s.count(a) == 1
s = s.replace(a, 'private var table: [String: Node] = [:]')
b = '        let key = Array(source.utf8)'
assert s.count(b) == 1
s = s.replace(b, '        let key = source')
c = 'let cost = produced.utf16.count * 2 + key.count'
assert s.count(c) == 1
s = s.replace(c, 'let cost = produced.utf16.count * 2 + key.utf8.count')
open(p, 'w').write(s)
PY
run_mutant string-key /tmp/mut-strkey.py

git checkout -- Sources/ Tests/
cd "$MAIN"
git worktree remove --force /tmp/r27-mut
cat "$OUT/receipt.txt"
echo "DONE $(date)"
