#!/usr/bin/env python3
"""Stack-level audit of the reopen profile's sources-build region (round-31):
counts rows whose stack contains a verify frame vs a real sources(of: frame,
showing the region is verify innards + KimiPart/ARC copy traffic, not source
rebuilding. Usage: sources-build-stack-audit.py <reopen-time-profile.xml>"""
import sys
import xml.etree.ElementTree as ET
SB = ["sources(of", "JSONValue", "visibleText", "KimiPart", "display"]
VER = ["sameSearchableWindow", "sameWindowBits", "sameWindow", "sameRenderedMessages", "sameRenderedPart", "sameRenderedUTF8"]
PRIOR = [["JSONWriter","JSONEncoder","display.getter","_writeJSON","_convertJSONString"],
         ["JSONSerialization","JSONDecoder","CFJSONSerialization"],
         ["RenderedSourceCache","ConversationEntryCache","NSLock"], VER,
         ["ReplyDocument","renderedText","ReplyBlock"], SB, ["role(of"],
         ["_nativeGetIndex","_nativeCopy","UTF16View","_bridgeToObjectiveC","_StringGuts","NSString"],
         ["rangeOfComposedCharacterSequences","substring(with","substring"],
         ["ConversationTimelineEntry"], ["sameQueryKey","sameRendered"],
         ["ConversationSearch"], ["deinit"]]
tree = ET.parse(sys.argv[1]); root = tree.getroot()
frame_cache, bt_cache = {}, {}
n = with_ver = with_src = 0
for row in root.iter('row'):
    bt = row.find('tagged-backtrace')
    if bt is None: continue
    ref = bt.get('ref')
    if ref is not None and ref in bt_cache: frames = bt_cache[ref]
    else:
        frames = []
        for fr in bt.findall('frame'):
            fref = fr.get('ref')
            if fref is not None and fref in frame_cache: frames.append(frame_cache[fref]); continue
            name = fr.get('name') or ''
            if fr.get('id'): frame_cache[fr.get('id')] = name
            frames.append(name)
        if bt.get('id'): bt_cache[bt.get('id')] = frames
    region = None
    for f in frames:
        for i, pats in enumerate(PRIOR):
            if any(p in f for p in pats): region = i; break
        if region is not None: break
    if region == 5:  # sources-build
        n += 1
        if any(any(p in f for p in VER) for f in frames): with_ver += 1
        if any('sources(of' in f for f in frames): with_src += 1
print(f"sources-build rows={n} with_verify_frame={with_ver} ({100*with_ver/max(n,1):.1f}%) with_real_sources_of={with_src} ({100*with_src/max(n,1):.1f}%)")
