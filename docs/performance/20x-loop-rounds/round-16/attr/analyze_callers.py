#!/usr/bin/env python3
"""Round-16 call-site ownership accounting for the cold find-bar trace.

Method (archived per re-review finding 1): every sample's resolved backtrace is
walked leaf-ward to root-ward; the FIRST frame naming one of the product call
sites below owns the sample ("nearest named product frame wins"). This differs
from analyze_findbar.py, which classifies by mechanism region (CF/DD/render/
bridge patterns) and therefore cannot answer "which product call site paid".

Outputs:
1. Total ownership per product call site (the linkMatches TOTAL).
2. For each selected hot leaf: ownership split by call site, plus how many of
   its samples carry an explicit `@objc __StringStorage.character(at:)` or
   `@objc __StringStorage.getCharacters(_:range:)` frame anywhere in the stack
   (the two bridging entry points the detector uses).
3. The removable-bridging subtotal (the seven leaves previously mislabeled as
   "linkMatches ~26%") and the CF query-match machinery subset under the
   search match loop.

Usage: analyze_callers.py <findbar-time-profile.xml>
"""
import sys
import xml.etree.ElementTree as ET
from collections import Counter

SITES = [
    ("linkMatches", ["linkMatches"]),
    ("linkBareURLs", ["linkBareURLs"]),
    ("ReplyDocument.parse", ["ReplyDocument.parse"]),
    ("ReplyDocument.blocks", ["ReplyDocument.blocks"]),
    ("ReplyDocument.inlines", ["ReplyDocument.inlines"]),
    ("renderedText", ["renderedText"]),
    ("sources(of:)", ["sources(of"]),
    ("role(of:)", ["role(of"]),
    ("ConversationSearch.search", ["ConversationSearch.search"]),
    ("ConversationSearch.hits", ["ConversationSearch.hits"]),
    ("ConversationTimelineEntry.make", ["ConversationTimelineEntry"]),
]

LEAVES = [
    "_nativeGetIndex",
    "langid_consume_string",
    "_DDScannerHandleState",
    "DDLexerDeterministicScan",
    "computeLexemsAtPosition",
    "__CF_IS_OBJC",
    "objc_msgSend",
    "_nativeCopy(into:alignedRange",
    "CFStringFindWithOptionsAndLocale",
    "__CFStringFoldCharacterClusterAtIndex",
]

BRIDGE_FRAMES = ["__StringStorage.character(at:)", "__StringStorage.getCharacters"]


def frames_of(row, frame_cache, bt_cache):
    bt = row.find("tagged-backtrace")
    if bt is None:
        return None
    ref = bt.get("ref")
    if ref is not None and ref in bt_cache:
        return bt_cache[ref]
    frames = []
    for fr in bt.findall("frame"):
        fr_ref = fr.get("ref")
        if fr_ref is not None and fr_ref in frame_cache:
            frames.append(frame_cache[fr_ref])
            continue
        name = fr.get("name") or ("0x" + (fr.get("addr") or "?"))
        if fr.get("id"):
            frame_cache[fr.get("id")] = name
        frames.append(name)
    if bt.get("id"):
        bt_cache[bt.get("id")] = frames
    return frames


def main():
    tree = ET.parse(sys.argv[1])
    root = tree.getroot()
    frame_cache, bt_cache = {}, {}
    total = 0
    site_counts = Counter()
    leaf_sites = {l: Counter() for l in LEAVES}
    leaf_totals = Counter()
    bridge_counts = Counter()
    for row in root.iter("row"):
        frames = frames_of(row, frame_cache, bt_cache)
        if not frames:
            continue
        total += 1
        site = None
        for f in frames:
            for name, pats in SITES:
                if any(p in f for p in pats):
                    site = name
                    break
            if site:
                break
        site_counts[site or "other/unattributed"] += 1
        leaf = frames[0]
        hit = next((l for l in LEAVES if l in leaf), None)
        if hit:
            leaf_totals[hit] += 1
            leaf_sites[hit][site or "other/unattributed"] += 1
            for b in BRIDGE_FRAMES:
                if any(b in f for f in frames):
                    bridge_counts[(hit, b)] += 1
    print(f"total_samples={total}")
    print("\n== total ownership (nearest named product frame wins) ==")
    for name, c in site_counts.most_common():
        print(f"{c:7d} {100.0*c/total:8.4f}%  {name}")
    print("\n== selected leaves: ownership + explicit bridging frames ==")
    for l in LEAVES:
        if not leaf_totals[l]:
            continue
        tops = ", ".join(f"{s}={c}" for s, c in leaf_sites[l].most_common(3))
        ca = bridge_counts.get((l, BRIDGE_FRAMES[0]), 0)
        gc = bridge_counts.get((l, BRIDGE_FRAMES[1]), 0)
        print(f"{l}: total={leaf_totals[l]} ({100.0*leaf_totals[l]/total:.4f}% of all)  [{tops}]"
              f"  character(at:)={ca} getCharacters={gc}")
    selected7 = ["_nativeGetIndex", "langid_consume_string", "_DDScannerHandleState",
                 "DDLexerDeterministicScan", "computeLexemsAtPosition", "__CF_IS_OBJC",
                 "objc_msgSend"]
    sub = sum(leaf_totals[l] for l in selected7)
    print(f"\nselected-7-leaf subtotal: {sub} ({100.0*sub/total:.4f}% of all)"
          f"  [the figure previously mislabeled as total linkMatches ownership]")
    search_leaves = ["CFStringFindWithOptionsAndLocale", "__CFStringFoldCharacterClusterAtIndex"]
    ss = sum(leaf_sites[l].get("ConversationSearch.search", 0) for l in search_leaves)
    print(f"CF query-match machinery under ConversationSearch.search "
          f"(CFStringFindWithOptionsAndLocale + __CFStringFoldCharacterClusterAtIndex only): "
          f"{ss} ({100.0*ss/total:.4f}% of all)")


if __name__ == "__main__":
    main()
