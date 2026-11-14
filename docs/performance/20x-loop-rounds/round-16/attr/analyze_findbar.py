#!/usr/bin/env python3
"""Region-classified aggregation of the round-16 cold find-bar query xctrace XML.

Same method as round-12 analyze_streaming_activity.py (innermost matching frame
wins), with the search region split into the cold path's candidate-relevant
sub-regions: CF locale/DD matching machinery (semantics red line), ReplyDocument
rendering, sources construction (tool JSON display), UTF-16/NSString bridging,
excerpt building, timeline synthesis and the residual search management
(dictionary/entry/array mechanics).

Usage: analyze_findbar.py <findbar-time-profile.xml>
"""
import sys
import xml.etree.ElementTree as ET
from collections import Counter

REGIONS = [
    ("setup-json", ["JSONSerialization", "JSONEncoder", "JSONDecoder", "CFJSONSerialization"]),
    ("setup-wire-decode", ["KimiWire", "KimiSnapshot.init", "KimiMessage.init(from",
                           "KimiPart.init(from", "init(from: Decoder)", "init(from:",
                           "KeyedDecodingContainer", "UnkeyedDecodingContainer",
                           "SingleValueDecodingContainer", "Decodable"]),
    # CF/locale/DataDetectors matching machinery — SEMANTICS RED LINE.
    ("cf-match", ["CFStringFind", "CFStringFold", "CFStringCompare", "__CFString",
                  "CFString", "langid", "DDScanner", "DDLexer", "DDToken",
                  "computeLexems", "StateQueryIterator", "rangeOfString",
                  "_CFAttributedString", "icu::", "ubrk", "u_str", "unidat",
                  "getGeneralCategory", "__CF_IS_OBJC"]),
    # ReplyDocument markdown parse + rendered-text assembly.
    ("render", ["ReplyDocument", "renderedText", "ReplyBlock"]),
    # Source string construction (tool JSON display, visibleText, part walks).
    ("sources-build", ["sources(of", "JSONValue", "visibleText", "KimiPart",
                       "display"]),
    ("role-derivation", ["role(of"]),
    # Swift<->NSString / UTF-16 conversion machinery.
    ("utf16-bridge", ["_nativeGetIndex", "_nativeCopy", "UTF16View",
                      "_bridgeToObjectiveC", "_StringGuts", "NSString"]),
    # Per-match excerpt building.
    ("excerpt", ["rangeOfComposedCharacterSequences", "substring(with",
                 "substring"]),
    # Timeline synthesis per call.
    ("timeline-make", ["ConversationTimelineEntry"]),
    # Window/query identity comparisons (should be minimal on pure cold calls).
    ("window-identity", ["sameSearchableWindow", "sameQueryKey", "sameRendered",
                         "rendersIdentically", "sameWindow"]),
    # Residual ConversationSearch mechanics: dictionary writes, Entry init,
    # hits concatenation, loop control.
    ("search-mgmt", ["ConversationSearch"]),
    ("teardown", ["deinit"]),
    ("bench-harness", ["benchFindBarColdProfileLoop", "benchNow", "fixture",
                       "median"]),
]

MECHANISMS = [
    "swift_retain", "swift_release", "initializeWithCopy", "destroy",
    "malloc", "free", "memmove", "memcpy", "Array.append",
    "_reserveCapacityAssumingUniqueBuffer", "Array._getElement", "_grow",
    "utf16", "String.index", "shouldBreak", "hasBreakWhenPaired",
    "validateUTF8", "String(decoding", "swift_allocObject",
    "operator new", "operator delete", "objc_", "withUnsafeBufferPointer",
    "Dictionary", "Hasher", "indexOf", "firstIndex",
]


def classify(frames):
    for f in frames:
        for label, pats in REGIONS:
            for p in pats:
                if p in f:
                    return label
    return "outside"


def main():
    path = sys.argv[1]
    tree = ET.parse(path)
    root = tree.getroot()
    frame_cache, bt_cache = {}, {}
    region_counts = Counter()
    region_leaves = {}
    incl = Counter()
    total = 0
    for row in root.iter("row"):
        bt = row.find("tagged-backtrace")
        if bt is None:
            continue
        ref = bt.get("ref")
        if ref is not None and ref in bt_cache:
            frames = bt_cache[ref]
        else:
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
        if not frames:
            continue
        total += 1
        region = classify(frames)
        region_counts[region] += 1
        region_leaves.setdefault(region, Counter())[frames[0]] += 1
        matched = set()
        for f in set(frames):
            for p in MECHANISMS:
                if p in f:
                    matched.add(p)
        for p in matched:
            incl[p] += 1

    setup_total = sum(c for r, c in region_counts.items() if r.startswith("setup-"))
    measured = total - setup_total
    print(f"profile=findbar-cold total_samples={total} setup={setup_total} "
          f"({100.0*setup_total/max(total,1):.1f}%) non_setup={measured} "
          f"({100.0*measured/max(total,1):.1f}%)")
    print("\n== region classification (innermost matching frame wins) ==")
    print(f"{'count':>7} {'%all':>7} {'%nonsetup':>10}  region")
    for label, c in region_counts.most_common():
        ns = 100.0 * c / measured if (not label.startswith("setup-") and measured) else 0.0
        print(f"{c:7d} {100.0*c/total:6.2f}% {ns:9.2f}%  {label}")
    for label, _ in region_counts.most_common():
        if label.startswith("setup-"):
            continue
        leaves = region_leaves.get(label)
        if not leaves:
            continue
        print(f"\n== top leaves in [{label}] ==")
        for name, c in leaves.most_common(18):
            print(f"{c:7d} {100.0*c/total:6.2f}%-of-all  {name[:160]}")
    print("\n== mechanism inclusive (samples with >=1 matching frame, all regions) ==")
    for p, c in incl.most_common():
        print(f"{c:7d} {100.0*c/total:6.2f}%  {p}")
    print("\n== top-40 self leaves overall ==")
    all_leaves = Counter()
    for leaves in region_leaves.values():
        all_leaves.update(leaves)
    for name, c in all_leaves.most_common(40):
        print(f"{c:7d} {100.0*c/total:6.2f}%  {name[:160]}")


if __name__ == "__main__":
    main()
