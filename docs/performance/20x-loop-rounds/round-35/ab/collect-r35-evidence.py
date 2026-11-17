#!/usr/bin/env python3
"""Round-35 evidence collector: copies receipts from .local/round35 and the
reviewer worktree into docs/performance/20x-loop-rounds/round-35/, applying
the sanitization conventions established in earlier rounds:
  /home/<dev> -> /home/<dev>      /Users/<mini> -> /Users/<mini>
  bare <dev> -> <dev>             bare <mini> -> <mini>
  /home/<runner> -> /home/<runner>       /Users/<runner> -> /Users/<runner>
Pair-level raw bench logs stay in .local (round-33 compact-receipt
convention: hashes/porcelain/rebuild/checks + summaries + analyzer).
Text files only; binaries are never copied.
"""
import pathlib
import shutil
import subprocess
import sys

REPO = pathlib.Path("/home/<dev>/.t3/worktrees/perch/t3-b3eb4bba-c5db753ed6879e15")
SRC = REPO / ".local/round35"
REVIEWER = pathlib.Path("/home/<dev>/.t3/worktrees/perch/t3-a23564d3-ad7f0db75d739d51/review-artifacts")
OUT = REPO / "docs/performance/20x-loop-rounds/round-35"

REPLACEMENTS = [
    ("/home/<dev>", "/home/<dev>"),
    ("/Users/<mini>", "/Users/<mini>"),
    ("/home/<runner>", "/home/<runner>"),
    ("/Users/<runner>", "/Users/<runner>"),
    ("<mini>", "<mini>"),
    ("<dev>", "<dev>"),
]

BINARY_SUFFIXES = {".png", ".jpg", ".zip", ".gz", ".pdf"}


def sanitize_bytes(data: bytes) -> bytes:
    text = data.decode("utf-8", errors="surrogateescape")
    for old, new in REPLACEMENTS:
        text = text.replace(old, new)
    return text.encode("utf-8", errors="surrogateescape")


def copy_sanitized(src: pathlib.Path, dst: pathlib.Path):
    if not src.exists():
        print("MISSING:", src)
        return False
    if src.suffix in BINARY_SUFFIXES:
        print("SKIP binary:", src)
        return False
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(sanitize_bytes(src.read_bytes()))
    return True


def copy_tree_sanitized(src_dir: pathlib.Path, dst_dir: pathlib.Path, patterns=None):
    if not src_dir.exists():
        print("MISSING DIR:", src_dir)
        return 0
    n = 0
    for p in sorted(src_dir.rglob("*")):
        if not p.is_file():
            continue
        if p.name in ("base-checks35v2", "cand-checks35v2", "base-checks35v3", "cand-checks35v3"):
            continue  # binaries
        if patterns and not any(p.match(pat) for pat in patterns):
            continue
        if copy_sanitized(p, dst_dir / p.relative_to(src_dir)):
            n += 1
    return n


def main():
    total = 0
    # --- ab/: summaries, analyzer, driver logs, jobs, receipt dirs ---
    ab = OUT / "ab"
    for name in ("analyze_r35.py", "linux-ab-v2-driver.log", "linux-ab-v3-driver.log",
                 "linux-ab-v2-summary.json", "linux-ab-v3-summary.json",
                 "macos-ab-v2-summary.json", "macos-ab-v3-summary.json",
                 "r35-ab-v2.job", "r35-ab-v3.job", "r35-token-retest.job",
                 "run-r35v2.sh", "run-r35v3.sh"):
        total += copy_sanitized(SRC / name, ab / name)
    # receipt dirs: compact set only (no pair logs, no build logs)
    receipt_pats = ("binary-hashes*.txt", "fixture-hashes*.txt", "main-porcelain-paths.txt",
                    "rebuild-receipt.txt", "checks-base.log", "checks-cand.log")
    for d in ("ab35v2", "ab35v3", "macos-ab-v2", "macos-ab-v3"):
        total += copy_tree_sanitized(SRC / d, ab / d, patterns=receipt_pats)
    # retest: everything (small) + the PerfRunner result log
    total += copy_tree_sanitized(SRC / "macos-ab-v3-retest", ab / "retest")
    log = subprocess.run(["ssh", "mac-mini",
                          "cat ~/Library/PerfRunner/results/r35-token-retest.log ~/Library/PerfRunner/results/r35-ab-v3.log 2>/dev/null"],
                         capture_output=True)
    if log.returncode == 0 and log.stdout:
        (ab / "retest").mkdir(parents=True, exist_ok=True)
        (ab / "retest" / "perfrunner-results-concat.log").write_bytes(sanitize_bytes(log.stdout))
        total += 1
    # --- mutations/ ---
    mut = OUT / "mutations"
    for name in ("mutation-kills-v2.sh", "mutation-kills-v3.sh",
                 "mutations-v2-driver.log", "mutations-v3-driver.log"):
        total += copy_sanitized(SRC / name, mut / name)
    for d in ("mutations-v2", "mutations-v3"):
        total += copy_tree_sanitized(SRC / d, mut / d)
    # also the earlier v1 battery dir if present
    if (SRC / "mutations").exists():
        total += copy_tree_sanitized(SRC / "mutations", mut / "mutations-v1")
    # --- review/ ---
    if REVIEWER.exists():
        total += copy_tree_sanitized(REVIEWER, OUT / "review")
    else:
        print("MISSING reviewer artifacts:", REVIEWER)
    # --- ci/ (round-32 compact convention: summary + quiet retest + the
    # native-math artifact only; the downloaded CI artifact tree also holds
    # a 437MB build.tar.zst and multi-MB unrelated results — excluded) ---
    total += copy_sanitized(SRC / "ci" / "math-summary-failed-0581fea.json",
                            OUT / "ci" / "math-summary-failed-0581fea.json")
    total += copy_sanitized(SRC / "ci" / "quiet-retest-0581fea.log",
                            OUT / "ci" / "quiet-retest-0581fea.log")
    total += copy_tree_sanitized(SRC / "ci" / "failed-math-0581fea" / "macos-results-native-math",
                                 OUT / "ci" / "failed-math-0581fea-native-math")
    total += copy_sanitized(SRC / "r35-math-retest.job", OUT / "ci" / "r35-math-retest.job")
    # --- attr/ ---
    total += copy_sanitized(SRC / "design-notes.md", OUT / "attr" / "design-notes.md")
    # --- portable receipt ---
    total += copy_sanitized(SRC / "portable-740b5f2" / "results.json",
                            OUT / "portable-results-740b5f2.json")
    # --- collector + kill scripts self-archive ---
    total += copy_sanitized(SRC / "collect-r35-evidence.py", ab / "collect-r35-evidence.py")
    print("copied", total, "files")
    # verify no personal identifiers leaked
    bad = []
    for p in OUT.rglob("*"):
        if p.is_file():
            data = p.read_bytes()
            for token in (b"<dev>", b"<mini>", b"/home/<runner>/"):
                if token in data:
                    bad.append((str(p.relative_to(OUT)), token.decode()))
    if bad:
        print("SANITIZATION FAILURES:", bad)
        sys.exit(1)
    print("sanitization verified clean")


if __name__ == "__main__":
    main()
