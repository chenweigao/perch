#!/usr/bin/env python3
"""Region-classified aggregation of round-33 find-bar xctrace XMLs (cold + reopen
shapes, post-round-32 ConversationPrefixCache). Extends the round-31 region list
with: store-walk (both caches' admission-cost walks + payload conversion + store
table work — the cold shape's new round-30/32 term), prefix-cache (prefix node
lookup/lock/generation/lastUse), prefix-verify (the ONE whole-window
sameSearchableWindow walk inside ConversationPrefixCache.node, split from the
per-entry verify region), and hits-copy (hits-array adoption copies).

Round-31 correction carried over (review finding): bare NSString retain/release
ARC leaves during hits-array copy/dealloc were absorbed by the cf-match
"CFString" pattern (8 of 523 reopen cf-match samples); rule A below reattributes
them to hits-copy by near-parent stack markers, so cf-match here is matching-only.

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
    # round-29 review correction: JSONValue.display (in-measurement source
    # building) serializes through JSONEncoder/JSONWriter and was previously
    # absorbed by the setup-json patterns. Split it out BEFORE setup-json so
    # fixture construction and measured display serialization are distinct.
    ("display-serialize", ["JSONWriter", "JSONEncoder", "display.getter",
                           "_writeJSON", "_convertJSONString"]),
    ("setup-json", ["JSONSerialization", "JSONDecoder", "CFJSONSerialization"]),
    ("setup-wire-decode", ["KimiWire", "KimiSnapshot.init", "KimiMessage.init(from",
                           "KimiPart.init(from", "init(from: Decoder)", "init(from:",
                           "KeyedDecodingContainer", "UnkeyedDecodingContainer",
                           "SingleValueDecodingContainer", "Decodable"]),
    # Round-30/32 admission-cost walks + store machinery (cold shape's new term).
    ("store-walk", ["admissionCost", "estimatedCost(of", "windowCost",
                    "jsonValueSize", "ConversationPrefixCache.store",
                    "ConversationEntryCache.store", "Payload.init"]),
    # Round-32 prefix node lookup machinery (table/lock/generation/lastUse).
    ("prefix-cache", ["ConversationPrefixCache"]),
    # Hits-array adoption copies (round-32 reference adoption still copies the
    # result array into the caller's `hits`).
    ("hits-copy", ["initializeWithCopy for ConversationSearchHit",
                   "destroy for ConversationSearchHit"]),
    # CF/locale/DataDetectors matching machinery — SEMANTICS RED LINE.
    ("cf-match", ["CFStringFind", "CFStringFold", "CFStringCompare", "__CFString",
                  "CFString", "langid", "DDScanner", "DDLexer", "DDToken",
                  "computeLexems", "StateQueryIterator", "rangeOfString",
                  "_CFAttributedString", "icu::", "ubrk", "u_str", "unidat",
                  "getGeneralCategory", "__CF_IS_OBJC"]),
    # Cross-instance cache machinery (round-27): lookup/insert/lock/key build.
    ("cache-mgmt", ["RenderedSourceCache", "ConversationEntryCache", "NSLock"]),
    # Round-30 verification predicate (reopen shape's main non-red-line cost).
    ("verify", ["sameSearchableWindow", "sameWindowBits", "sameWindow", "sameRenderedMessages", "sameRenderedPart", "sameRenderedUTF8"]),
    # ReplyDocument markdown parse + rendered-text assembly.
    ("render", ["ReplyDocument", "renderedText", "ReplyBlock"]),
    # Per-instance joined searchable text construction.
    ("join-concat", ["joined(separator", "String.join", "specialized join"]),
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
    ("bench-harness", ["benchFindBarColdProfileLoop", "benchR29Profile", "benchR31Profile",
                       "benchR33Profile", "benchNow", "fixture", "median"]),
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


ARC_LEAVES = ("-[__NSCFString release]", "-[__NSCFString retain]")
HITS_MARKERS = ("ConversationSearchHit", "swift_arrayInitWithCopy")
DESTROY_MARKERS = ("swift_arrayDestroy", "_ContiguousArrayStorage.__deallocating_deinit",
                   "outlined destroy", "swift_release_dealloc")


def classify(frames):
    # Rule A (round-31 review correction): NSString ARC leaves whose near
    # parents are hits-array copy machinery are hits-copy work, not CF
    # matching (the "CFString" pattern would otherwise absorb them).
    if frames[0] in ARC_LEAVES and any(
            any(m in f for m in HITS_MARKERS) for f in frames[1:6]):
        return "hits-copy"
    # Rule A2 (round-33 review N1): NSString ARC leaves under generic
    # array-destroy machinery cannot be proven hits-typed — classify them as
    # teardown/ARC, NOT cf-match (keeps cf-match matching-only as documented).
    if frames[0] in ARC_LEAVES and any(
            any(m in f for m in DESTROY_MARKERS) for f in frames[1:6]):
        return "teardown"
    # Rule B: samples inside the prefix node lookup split into table
    # machinery (prefix-cache) and the whole-window verification walk
    # (prefix-verify), which per-entry regions cannot distinguish.
    node_idx = next((i for i, f in enumerate(frames)
                     if "ConversationPrefixCache.node(" in f), None)
    if node_idx is not None:
        inner = frames[:node_idx]
        for f in inner:
            if ("__RawDictionaryStorage" in f or "Hasher" in f or "NSLock" in f
                    or "pthread_mutex" in f or "_platform_memmove" in f):
                return "prefix-cache"
        return "prefix-verify"
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
    profile = sys.argv[2] if len(sys.argv) > 2 else "findbar"
    print(f"profile={profile} total_samples={total} setup={setup_total} "
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
