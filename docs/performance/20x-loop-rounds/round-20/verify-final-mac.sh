#!/bin/bash
# Round-20 final-form Mac verification: product == c085fd9 (both candidates
# reverted) + final pins (narrative golden + localization chain with the
# Darwin branch). SwiftPM scratch build, binary run IN PLACE (round-18
# lesson; relocated binaries are SIGKILLed on this machine).
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261115"
RES="$LOGS/verify20"
rm -rf "$RES"; mkdir -p "$RES"
git fetch origin
git checkout --detach c085fd9
git checkout -- . 2>/dev/null; git clean -fdq Sources/ Tests/
echo "HEAD=$(git rev-parse HEAD)"
git apply "$LOGS/r20-final-tests.patch" && echo tests_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round20-verify > "$RES/build.log" 2>&1
echo "build_exit=$?"
BIN="$PWD/.build/round20-verify/out/Products/Release/WorkbenchChecks"
shasum -a 256 "$BIN"
"$BIN" > "$RES/checks.log" 2>&1; echo "checks_exit=$? pass=$(grep -c '^PASS' "$RES/checks.log")"
grep -E 'narrative byte-keyed|localization resolution|link detection|delimiter|splitInline' "$RES/checks.log"
git checkout -- . ; git clean -fdq Tests/
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
