#!/usr/bin/env python3
"""Round-43 decode-free composition (lineage: round-41 ad-hoc analysis,
reconstructed and saved this round). Splits chain-phase samples into
decode-ancestry (harness restart wire-decode, not product cost) vs
decode-free; reports innermost-region composition and product-function
INCLUSIVE shares over the decode-free denominator."""
import sys
from collections import Counter
sys.path.insert(0, '.local/round43')
from analyze_r43 import load, classify, REGIONS

DECODE_LABELS = {"setup-wire-decode", "setup-json"}
DECODE_PATS = []
for label, pats in REGIONS:
    if label in DECODE_LABELS:
        DECODE_PATS.extend(pats)

PRODUCT = [
    ("displayMessages.getter", ["displayMessages"]),
    ("DisplayMemoBox.value", ["DisplayMemoBox"]),
    ("KimiInFlight.appendDelta", ["appendDelta"]),
    ("KimiMessage.sameWindow", ["sameWindow(_:_:)"]),
    ("KimiMessage.sameWindowBits", ["sameWindowBits"]),
    ("sameRendered family", ["sameRendered"]),
    ("TV.canReuse", ["canReuse"]),
    ("TV.projectTurns", ["projectTurns"]),
    ("TV.Pass.normalize", ["Pass.normalize"]),
    ("ConversationTimelineEntry.make", ["ConversationTimelineEntry"]),
    ("History.presented", ["History.presented", "History.joined"]),
    ("Snapshot.presented", ["Snapshot.presented"]),
    ("ConversationPresentationModel", ["ConversationPresentationModel"]),
    ("ActivityNarrativeProjection.make", ["ActivityNarrativeProjection"]),
    ("NarrativeTextCache", ["NarrativeTextCache"]),
    ("CommentaryDerivation", ["CommentaryDerivation"]),
    ("ActivityNarrativeSnapshot.clean", ["ActivityNarrativeSnapshot.clean", "snapshot.clean"]),
    ("ActivityNarrativeSnapshot.narrativeText", ["narrativeText"]),
    ("NarrativePhaseScan", ["NarrativePhaseScan"]),
    ("ConversationActivity.init", ["ConversationActivity"]),
    ("ConversationSearch.search", ["ConversationSearch"]),
    ("ToolVisibilityProjection", ["ToolVisibilityProjection"]),
]

def main():
    rows = load(sys.argv[1])
    frames = [fr for _, fr in rows]
    total = len(frames)
    def is_decode(fr):
        return any(any(p in f for p in DECODE_PATS) for f in fr)
    dec = [fr for fr in frames if is_decode(fr)]
    free = [fr for fr in frames if not is_decode(fr)]
    print(f"total={total} decode-ancestry={len(dec)} ({100.0*len(dec)/total:.2f}%) decode-free={len(free)}")
    n = len(free)
    print(f"\n== decode-free innermost-region composition (n={n}) ==")
    for label, c in Counter(classify(fr) for fr in free).most_common():
        if c * 100.0 / n < 0.05:
            continue
        print(f"    {c:5d} {100.0*c/n:6.2f}%  {label}")
    print(f"\n== product-function inclusive shares (decode-free denominator) ==")
    for name, pats in PRODUCT:
        c = sum(1 for fr in free if any(any(p in f for p in pats) for f in fr))
        print(f"    {c:5d} {100.0*c/n:6.2f}%  {name}")

if __name__ == "__main__":
    main()
