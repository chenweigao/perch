#!/bin/bash
# Round-20 full checks on both sides with the embedded golden.
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
MAIN=<worktree>
cd "$MAIN"
out=.local/round20/checks
mkdir -p "$out"
echo "=== base (c085fd9 + final Tests) $(date) ==="
git worktree remove --force /tmp/r20-base >/dev/null 2>&1; rm -rf /tmp/r20-base; git worktree prune
git worktree add --detach /tmp/r20-base c085fd9 >/dev/null 2>&1 || { echo WORKTREE_FAIL; exit 1; }
rm -rf /tmp/r20-base/Tests && cp -R "$MAIN/Tests" /tmp/r20-base/Tests
(cd /tmp/r20-base && swift build -c release --product WorkbenchChecks > build.log 2>&1; echo "base_build_exit=$?")
/tmp/r20-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks > "$out/checks-base.log" 2>&1
echo "base_checks_exit=$? pass=$(grep -c '^PASS' "$out/checks-base.log") skip=$(grep -c '^SKIP' "$out/checks-base.log")"
grep "narrative byte-keyed" "$out/checks-base.log"
echo "=== candidate (working tree) $(date) ==="
swift build -c release --product WorkbenchChecks > /tmp/r20-cand-build.log 2>&1; echo "cand_build_exit=$?"
.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks > "$out/checks-cand.log" 2>&1
echo "cand_checks_exit=$? pass=$(grep -c '^PASS' "$out/checks-cand.log") skip=$(grep -c '^SKIP' "$out/checks-cand.log")"
grep "narrative byte-keyed" "$out/checks-cand.log"
echo "=== goldens on both sides ==="
grep -h "digest" "$out/checks-base.log" | grep -E "link detection|normalizeDelimiters|splitInline|narrative"
echo "-- cand --"
grep -h "digest" "$out/checks-cand.log" | grep -E "link detection|normalizeDelimiters|splitInline|narrative"
git worktree remove --force /tmp/r20-base
echo "DONE $(date)"
