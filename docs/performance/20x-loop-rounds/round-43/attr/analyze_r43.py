#!/usr/bin/env python3
"""Round-36 attribution: paging-shape Time Profiler XML (post-round-35 base fd79884).
Lineage: analyze_r34.py (regions + phase segmentation + consumer attribution
unchanged; streaming sections simply unused for a paging-only trace).

Method: innermost-matching-frame regions (round-12/16/29/31/33 lineage) with a
presentation-chain region vocabulary, PLUS phase segmentation for the paging
trace (harness cycles = [cold projection][35 warm delta updates][20 measured
page prepends]; warm phases carry JSONSerialization/KimiWire/apply frames,
prepend phases carry presented(activity:)/ProcessFold/Activity frames and no
JSON frames — '.' samples resolve by next-marker lookahead).

Streaming needs no phase split (restart decode is ~3% and classifies into the
setup-* regions; the update chain is the rest).

Usage: analyze_r36.py <xml> <profile-name>
"""
import sys
import xml.etree.ElementTree as ET
from collections import Counter

REGIONS = [
    # fixture / event decode / restart
    ("setup-json", ["JSONSerialization", "CFJSONSerialization"]),
    ("setup-wire-decode", ["KimiWire", "JSONDecoder", "JSONScanner", "KimiSnapshot.init",
                           "KimiMessage.init(from", "KimiPart.init(from", "init(from: Decoder)",
                           "init(from:", "KeyedDecodingContainer", "UnkeyedDecodingContainer",
                           "SingleValueDecodingContainer", "Decodable"]),
    ("apply-event", ["KimiConversation.apply", "KimiEvent"]),
    # find-bar machinery (streaming chain includes query_update; r33 vocabulary)
    ("find-prefix-cache", ["ConversationPrefixCache"]),
    ("find-entry-cache", ["ConversationEntryCache"]),
    ("find-render-cache", ["RenderedSourceCache"]),
    ("find-verify", ["sameSearchableWindow", "sameWindowBits", "sameRenderedMessages",
                     "sameRenderedPart", "sameRenderedUTF8"]),
    ("find-search", ["ConversationSearch"]),
    # presentation chain
    ("narrative", ["ActivityNarrativeProjection", "NarrativeTextCache", "narrativeText"]),
    ("tool-visibility", ["ToolVisibilityProjection"]),
    ("history-join", ["History.joined", "History.init", "PresentationModel.History"]),
    ("input-compare", ["sameWindow", "ConversationPresentationModel.Input", "inputComparison"]),
    ("timeline-make", ["ConversationTimelineEntry"]),
    ("row-build", ["RowProjection", "rowProjection", "ConversationRow"]),
    ("turn-summary", ["TurnSummary", "turnSummary", "SummaryProjection"]),
    ("presented-fold", ["presented(activity", "ConversationProcessFold", "foldedRows"]),
    ("activity-init", ["ConversationActivity"]),
    ("display-messages", ["displayMessages"]),
    ("model-update", ["ConversationPresentationModel.update", "ConversationPresentationHandle.update"]),
    # generic mechanisms (last resort)
    ("cf-match", ["CFStringFind", "CFStringFold", "CFStringCompare", "__CFString",
                  "CFString", "langid", "DDScanner", "DDLexer", "DDToken",
                  "computeLexems", "StateQueryIterator", "rangeOfString",
                  "_CFAttributedString", "icu::", "ubrk", "u_str", "unidat",
                  "getGeneralCategory", "__CF_IS_OBJC"]),
    ("string-hash", ["Hasher.combine(bytes:)", "Hasher._finalize", "Hasher.init",
                     "String.hash(into:)", "_rawHashValue", "_StringBreadcrumbs"]),
    ("dict-find", ["__RawDictionaryStorage", "_HashTable", "_NativeDictionary"]),
    ("string-compare", ["_stringCompare", "_StringGuts", "validateUTF8", "String.==",
                        "outlined compare"]),
    ("utf16-bridge", ["_nativeGetIndex", "_nativeCopy", "UTF16View", "_bridgeToObjectiveC",
                      "NSString", "bridgeObject"]),
    ("arc-copy", ["initializeWithCopy", "swift_arrayInitWithCopy", "_copyContents", "memmove",
                  "swift_retain", "swift_release", "swift_bridgeObjectRetain",
                  "swift_bridgeObjectRelease", "DYLD-STUB$$swift_bridge"]),
    ("teardown", ["deinit", "swift_arrayDestroy", "__deallocating_deinit", "Destroy", "destroy",
                  "_free", "xzm_free", "malloc_zone_free"]),
    ("alloc", ["malloc", "allocObject", "slowAlloc", "xzm_malloc", "operator new"]),
    ("bench-harness", ["benchR34", "benchNow", "fixture", "median"]),
]

WARM_MARKERS = ("JSONSerialization", "KimiWire", "JSONDecoder", "JSONScanner",
                "KimiConversation.apply", "init(from:")
PREPEND_MARKERS = ("presented(activity", "ConversationProcessFold", "ConversationActivity")


def marker(frames):
    s = " ".join(frames[:40])
    if any(m in s for m in WARM_MARKERS):
        return "J"
    if any(m in s for m in PREPEND_MARKERS):
        return "P"
    return "."


def classify(frames):
    for f in frames:
        for label, pats in REGIONS:
            for p in pats:
                if p in f:
                    return label
    return "outside"


def load(path):
    tree = ET.parse(path)
    root = tree.getroot()
    fc, bc, rows = {}, {}, []
    for row in root.iter("row"):
        bt = row.find("tagged-backtrace")
        if bt is None:
            continue
        st = row.find("sample-time")
        t = float(st.text) if st is not None else None
        ref = bt.get("ref")
        if ref is not None and ref in bc:
            frames = bc[ref]
        else:
            frames = []
            for fr in bt.findall("frame"):
                fref = fr.get("ref")
                if fref is not None and fref in fc:
                    frames.append(fc[fref])
                    continue
                name = fr.get("name") or ("0x" + (fr.get("addr") or "?"))
                if fr.get("id"):
                    fc[fr.get("id")] = name
                frames.append(name)
            if bt.get("id"):
                bc[bt.get("id")] = frames
        if frames:
            rows.append((t, frames))
    return rows


def main():
    path, profile = sys.argv[1], sys.argv[2]
    rows = load(path)
    n = len(rows)
    phases = [None] * n
    if profile == "paging":
        marks = [marker(fr) for _, fr in rows]
        nxtJ = [2 * n] * n
        nxtP = [2 * n] * n
        lj = lp = 2 * n
        for i in range(n - 1, -1, -1):
            nxtJ[i], nxtP[i] = lj, lp
            if marks[i] == "J":
                lj = i
            elif marks[i] == "P":
                lp = i
        for i, m in enumerate(marks):
            if m == "J":
                phases[i] = "warm"
            elif m == "P":
                phases[i] = "prepend"
            else:
                phases[i] = "prepend" if nxtP[i] < nxtJ[i] else "warm"
    else:
        phases = ["chain"] * n

    print(f"profile={profile} total_samples={n}")
    for phase in sorted(set(phases)):
        sub = [fr for fr, p in zip((fr for _, fr in rows), phases) if p == phase]
        if not sub:
            continue
        counts = Counter(classify(fr) for fr in sub)
        print(f"\n== phase [{phase}] n={len(sub)} ({100.0*len(sub)/n:.1f}% of trace) ==")
        for label, c in counts.most_common():
            if c * 100.0 / len(sub) < 0.05:
                continue
            print(f"  {c:6d} {100.0*c/len(sub):6.2f}%  {label}")
        leaves = Counter(fr[0] for fr in sub)
        print(f"  -- top leaves --")
        for name, c in leaves.most_common(14):
            print(f"  {c:6d} {100.0*c/len(sub):6.2f}%  {name[:120]}")
        # consumer attribution for hash/dict leaves
        consumers = Counter()
        for fr in sub:
            if any(x in fr[0] for x in ("Hasher", "__RawDictionaryStorage", "_StringBreadcrumbs", "String.hash")):
                for p in fr[1:10]:
                    if any(x in p for x in ("swift_", "outlined", "DYLD", "_platform", "Hasher",
                                            "_Native", "Dictionary.", "Set.", "_HashTable",
                                            "__RawDictionary", "protocol witness for Hashable")):
                        continue
                    consumers[p[:90]] += 1
                    break
        if consumers:
            print("  -- hash/dict consumers --")
            for name, c in consumers.most_common(8):
                print(f"  {c:6d} {100.0*c/len(sub):6.2f}%  {name}")


if __name__ == "__main__":
    main()
