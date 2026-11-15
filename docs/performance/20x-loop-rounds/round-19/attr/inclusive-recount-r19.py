#!/usr/bin/env python3
"""Round-19 review F1 self-verification: inclusive splitInline attribution.

Recomputes the reviewer's inclusive counts from the archived round-17 cold
find-bar trace (.local/round17/findbar-time-profile.xml, 21,222 samples):
  - samples whose backtrace contains the splitInline CLOSURE frame;
  - samples containing ANY splitInline frame;
  - samples containing a `contains` frame LEAF-WARD of a splitInline frame
    (frames are stored leaf-first in the resolved backtrace).

Result (matches the review's numbers exactly — see inclusive-recount-r19.txt):
  total=21222, closure=1199 (5.649797%), any=1290 (6.078598%),
  contains-under=1163 (5.480162%).

The round-17 report's "splitInline closure 795 (3.7%)" is NOT reproducible
from the archived trace under any inclusive definition; it was an
accounting-bucket figure whose generating invocation was not archived. The
round-19 documents therefore cite ONLY the inclusive counts defined here.

Usage: inclusive-recount-r19.py <findbar-time-profile.xml>
"""
import sys
import xml.etree.ElementTree as ET

tree = ET.parse(sys.argv[1] if len(sys.argv) > 1 else ".local/round17/findbar-time-profile.xml")
root = tree.getroot()

frame_name = {}
for f in root.iter("frame"):
    fid = f.attrib.get("id")
    if fid:
        frame_name[fid] = f.attrib.get("name", "")

def resolve_frames(tb):
    out = []
    for f in tb.findall("frame"):
        if "ref" in f.attrib:
            out.append(frame_name.get(f.attrib["ref"], ""))
        else:
            out.append(f.attrib.get("name", ""))
    return out

bt_by_id = {}
samples = []
for row in root.findall(".//row"):
    tb = row.find("tagged-backtrace")
    if tb is None:
        continue
    if "id" in tb.attrib:
        frames = resolve_frames(tb)
        bt_by_id[tb.attrib["id"]] = frames
        samples.append(frames)
    else:
        samples.append(bt_by_id[tb.attrib["ref"]])

total = len(samples)
closure = any_f = contains_under = 0
for frames in samples:
    si = [i for i, f in enumerate(frames) if "splitInline" in f]
    if any("closure #1 in static ReplyMath.splitInline" in f for f in frames):
        closure += 1
    if si:
        any_f += 1
        if any("contains" in frames[i] for i in range(min(si))):
            contains_under += 1

print(f"total={total}")
print(f"closure: {closure} ({closure/total*100:.6f}%)")
print(f"any splitInline frame: {any_f} ({any_f/total*100:.6f}%)")
print(f"contains leaf-ward of splitInline: {contains_under} ({contains_under/total*100:.6f}%)")
