#!/usr/bin/env python3
"""Round-44 supplementary views for the leaf-bucket attribution.

The union table in `analyze_r44_consumers.py` answers "who owns this sample".
Three follow-up questions decide whether the numbers are actionable, and each
one was raised in review:

1. The `Array.+ infix` consumer covers every array concatenation in the chain —
   the chain has several (`displayMessages` cold path, `Snapshot.presented`,
   `Model.update`, navigation). Split those samples by the next real ancestor.
2. The find-bar line total: `ConversationSearch` plus the NSDataDetector /
   CoreNLP / MeCab frames it calls. Sum them explicitly instead of hand-adding.
3. Unresolved frames (`0x...` addresses) must be reported, not silently folded
   into a consumer.

Usage: analyze_r44_views.py <xml>
"""
import sys
from collections import Counter, defaultdict
from pathlib import Path

_ROUNDS = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_ROUNDS / 'round-44' / 'attr'))
from analyze_r44_consumers import (load, classify, consumer, is_decode, is_mechanism, unmodified)

TARGETS = ("utf16-bridge", "arc-copy", "cf-match", "teardown")
FIND_BAR = ("ConversationSearch", "NSDataDetector", "CoreNLP", "MeCab", "DDLookup",
            "_fetchNextToken", "_FillNextTokenInCache", "__btrie", "DDLexem", "utext_",
            "ICUTextBreak", "DDScanner", "DDToken", "computeLexems", "ubrk_", "u_str",
            "ReplyDocument",
            # ICU / NL tokenizer plumbing reached from the detector (review round 3)
            "unorm2", "ucptrie", "NLStringTokenizer")


def next_ancestor(frames, predicate):
    """First frame above the first frame matching `predicate` that is neither a
    mechanism frame nor another instance of the same symbol family."""
    seen = False
    for frame in frames:
        if not seen:
            if predicate(frame):
                seen = True
            continue
        if is_mechanism(frame) or predicate(frame):
            continue
        if frame.startswith("0x"):
            return "<unresolved-system>"
        return frame[:110]
    return "<no-ancestor>"


def main():
    rows = load(sys.argv[1])
    free = [fr for _, fr in rows if not is_decode(fr)]
    n = len(free)
    print(f"decode-free n={n}")

    concat = [fr for fr in free if classify(fr) in TARGETS]
    print(f"\n== target buckets: {len(concat)} samples ({100.0*len(concat)/n:.2f}%) ==")

    # 1) Array.+ split by its caller
    plus = [fr for fr in concat if any("Array.+ infix" in f for f in fr)
            and consumer(fr) and "Array.+ infix" in consumer(fr)]
    split = Counter(next_ancestor(fr, lambda f: "Array.+ infix" in f) for fr in plus)
    total_plus = sum(split.values())
    print(f"\n== Array.+ samples split by caller (n={total_plus}, "
          f"{100.0*total_plus/n:.2f}% of decode-free) ==")
    for name, c in split.most_common(12):
        print(f"  {c:5d} {100.0*c/max(total_plus,1):6.2f}% of Array.+ | "
              f"{100.0*c/n:5.2f}% of decode-free  {name}")

    # 2) find-bar line total
    consumers = Counter(consumer(fr) for fr in concat)
    findbar = sum(c for name, c in consumers.items() if any(p in name for p in FIND_BAR))
    print(f"\n== find-bar line (search + detector internals) ==")
    for name, c in consumers.most_common():
        if any(p in name for p in FIND_BAR):
            print(f"  {c:5d} {100.0*c/n:5.2f}%  {name}")
    print(f"  total {findbar} = {100.0*findbar/n:.2f}% of decode-free")

    # 3) unresolved / harness / product split
    # Closures, `stamp`, the bench driver and the test entry point all belong to
    # the harness rather than to product code (review rounds 2-3).
    HARNESS = ("benchR43Profile", "benchStreamingDelta", "ProtocolTests.main")
    def is_harness(name):
        return any(h in name for h in HARNESS) or name.startswith("stamp")
    harness = sum(c for name, c in consumers.items() if is_harness(name))
    unresolved = sum(c for name, c in consumers.items()
                     if name.startswith("<unresolved") or name.startswith("<no-"))
    product = sum(c for name, c in consumers.items()
                  if not any(p in name for p in FIND_BAR)
                  and not is_harness(name) and not name.startswith("<"))
    print(f"\n== category totals over the four buckets (n={len(concat)}) ==")
    for label, value in [("find-bar line", findbar), ("harness", harness),
                         ("unresolved", unresolved), ("product", product)]:
        print(f"  {value:5d} {100.0*value/n:5.2f}% of decode-free  {label}")
    print(f"  (sum {findbar+harness+unresolved+product} vs {len(concat)} sampled; "
          f"difference = consumers below the print cut)")

    # 4) largest product consumers
    print(f"\n== product consumers (each < the table) ==")
    ranked = sorted(((c, name) for name, c in consumers.items()
                     if not any(p in name for p in FIND_BAR)
                     and not is_harness(name) and not name.startswith("<")), reverse=True)
    for c, name in ranked[:12]:
        print(f"  {c:5d} {100.0*c/n:5.2f}%  {name}")


if __name__ == "__main__":
    main()