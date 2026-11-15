#!/usr/bin/env python3
"""Round-20 attribution analyzer: presentation-token Time Profiler trace.

Resolves the archived xctrace XML (id/ref frames), scopes samples to the
narrative stage (backtraces carrying ActivityNarrativeProjection.make — the
stage the product's own ConversationPresentationUpdateMetrics instrument
wraps), and reports: top leaves inside the stage, mechanism buckets for the
candidate hypotheses (H1 phase contains/lowercased, H2 clean charset/trim,
H3 steps deep-equal, H4 dictionary hashing of full-text String keys,
H5 grapheme counts), and caller drill-downs of the hashing/compare leaves.

Usage: analyze-presentation.py <presentation-time-profile.xml>
"""
import sys
import xml.etree.ElementTree as ET
from collections import Counter

tree = ET.parse(sys.argv[1] if len(sys.argv) > 1 else ".local/round20/presentation-time-profile.xml")
root = tree.getroot()
frame_name = {}
for f in root.iter("frame"):
    fid = f.attrib.get("id")
    if fid:
        frame_name[fid] = f.attrib.get("name", "")

def resolve(tb):
    return [frame_name.get(f.attrib["ref"], "") if "ref" in f.attrib else f.attrib.get("name", "")
            for f in tb.findall("frame")]

bt_by_id, samples = {}, []
for row in root.findall(".//row"):
    tb = row.find("tagged-backtrace")
    if tb is None:
        continue
    if "id" in tb.attrib:
        fr = resolve(tb)
        bt_by_id[tb.attrib["id"]] = fr
        samples.append(fr)
    else:
        samples.append(bt_by_id[tb.attrib["ref"]])

tot = len(samples)
narr = [fr for fr in samples if any("ActivityNarrativeProjection.make" in f for f in fr)]
print(f"total={tot}  narrative-make inclusive={len(narr)} ({len(narr)/tot*100:.2f}%)")

leaves = Counter(fr[0] for fr in narr)
print("== top leaves inside make() ==")
for k, v in leaves.most_common(25):
    print(f"   {v:5d} {v/tot*100:5.2f}%-of-all {v/len(narr)*100:5.2f}%-of-narr  {k[:88]}")

MECH = {
    "H1-phase-contains": ["StringProtocol.contains", "StringProtocol.range", "_stringCompare",
                          "_StringCompareOptions", "lowercased", "CaseMapping", "_getMapping"],
    "H2-clean-charset": ["CharacterSet", "union", "trimmingCharacters", "collapsedWhitespace"],
    "H5-count-grapheme": ["String.count", "count.getter", "_opaqueComplexCharacterStride",
                          "shouldBreak", "hasBreakWhenPaired", "index(_:offsetBy:limitedBy:)"],
    "H3-deep-equal": ["KimiMessage.==", "KimiPart.==", "static KimiMessage", "outlined compare", "JSONValue.=="],
    "H4-lock-dict-hash": ["NSLock", "objc_sync", "Hasher", "Dictionary", "_RawDictionaryStorage",
                          "Set.", "_NativeSet"],
}
for name, pats in MECH.items():
    hits = [fr for fr in narr if any(any(p in f for f in fr) for p in pats)]
    print(f"{name}: {len(hits)} ({len(hits)/len(narr)*100:.2f}% of narr)")

SITES = ["NarrativeTextCache", "static ActivityNarrativeSnapshot.clean", "narrativeText",
         "phase(from", "ActivityNarrativeProjection", "steps(for", "value(", "Dictionary",
         "Set", "hashValue", "Hashable", "_NativeDictionary", "_DictionaryStorage"]
for leaf in ["Hasher._combine", "_fastNFCCheck", "withFastUTF8", "_stringCompareFastUTF8Abnormal", "_normalizedHash"]:
    hits = [fr for fr in narr if any(leaf in f for f in fr)]
    if not hits:
        continue
    owners = Counter()
    for fr in hits:
        li = max(i for i, f in enumerate(fr) if leaf in f)
        owner = None
        for f in fr[li + 1:]:
            if any(s in f for s in SITES):
                owner = f
                break
        owners[owner or "(none)"] += 1
    print(f"\n== {leaf}: {len(hits)} ({len(hits)/len(narr)*100:.2f}% of narr) ==")
    for k, v in owners.most_common(5):
        print(f"     {v:5d}  {k[:100]}")

print("\n== sample backtrace containing _fastNFCCheck (leaf-ward first 16) ==")
for fr in narr:
    if any("_fastNFCCheck" in f for f in fr):
        for f in fr[:16]:
            print("   ", f[:110])
        break
