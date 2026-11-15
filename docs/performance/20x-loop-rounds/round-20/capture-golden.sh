#!/bin/bash
# Round-20 golden capture: UNMODIFIED product (c085fd9) + pin, then candidate.
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
MAIN=<worktree>
cd "$MAIN"
out=.local/round20/capture
mkdir -p "$out"
echo "=== save candidate-side working tree state ==="
git status --porcelain > "$out/candidate-porcelain.txt"
cat "$out/candidate-porcelain.txt"
echo "=== build BASE (c085fd9 + working-tree Tests = pin only, unmodified product) $(date) ==="
git worktree remove --force /tmp/r20-base >/dev/null 2>&1
rm -rf /tmp/r20-base
git worktree prune
git worktree add --detach /tmp/r20-base c085fd9 >/dev/null 2>&1 || { echo WORKTREE_ADD_FAILED; exit 1; }
rm -rf /tmp/r20-base/Tests && cp -R "$MAIN/Tests" /tmp/r20-base/Tests
diff "$MAIN/Sources/WorkbenchCore/ActivityNarrative.swift" /tmp/r20-base/Sources/WorkbenchCore/ActivityNarrative.swift > "$out/product-diff-base-vs-cand.txt" && echo "PRODUCT_IDENTICAL=yes" || echo "PRODUCT_IDENTICAL=no (expected: base has the OLD cache)"
(cd /tmp/r20-base && swift build -c release --product WorkbenchChecks > build.log 2>&1; echo "base_build_exit=$?")
echo "=== run base checks (capture digest from trap; expect nonzero exit at the golden assert) ==="
/tmp/r20-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks > "$out/capture-base.log" 2>&1
echo "base_checks_exit=$?"
grep -oE "digest changed: [0-9a-f]{16}" "$out/capture-base.log" | head -1
grep -c "^PASS" "$out/capture-base.log"
echo "DONE $(date)"
