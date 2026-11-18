#!/usr/bin/env python3
"""Round-44 leaf-bucket consumer attribution (lineage: analyze_r43.py).

Round-39 F3 doctrine: generic leaf buckets (utf16-bridge / arc-copy / cf-match /
teardown) are NOT mutually exclusive attack partitions — each sample must be
attributed to the nearest enclosing NON-mechanism frame (its consumer) before
any attackable share can be claimed.

Method: reuse round-43's loader/classifier and decode-ancestry filter. For every
decode-free sample whose innermost region is a target bucket, walk from the leaf
upward skipping mechanism frames (generic buckets + Swift/CF runtime + allocator
plumbing) and attribute the sample to the first remaining frame, truncated to a
stable symbol prefix.

Usage: analyze_r44_consumers.py <xml> [bucket ...]
"""
import sys
from collections import Counter, defaultdict
from pathlib import Path

# The round-43 analyzer is committed next to this evidence set; resolve it from
# this file so the script runs from any working directory (repo root included).
_ROUNDS = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_ROUNDS / 'round-43' / 'attr'))
from analyze_r43 import load, classify, REGIONS

DECODE_LABELS = {"setup-wire-decode", "setup-json"}
DECODE_PATS = []
for label, pats in REGIONS:
    if label in DECODE_LABELS:
        DECODE_PATS.extend(pats)

MECHANISM_LABELS = {
    "cf-match", "string-hash", "dict-find", "string-compare",
    "utf16-bridge", "arc-copy", "teardown", "alloc",
}
MECHANISM_PATS = []
for label, pats in REGIONS:
    if label in MECHANISM_LABELS:
        MECHANISM_PATS.extend(pats)

# Frames that are still runtime plumbing even when they are the nearest
# non-generic-bucket frame (ARC slow paths, array grow/copy, string storage
# helpers).  Round-44 first run showed these swallow 60-70% of the buckets,
# so attribution must walk past them to real product code.
RUNTIME_HELPER_PATS = (
    "RefCounts<", "doDecrementSlow", "doIncrementSlow", "swift::RefCounts",
    "_ContiguousArrayBuffer", "_Variant.setValue", "_Variant.find",
    "Array._createNewBuffer", "UnsafeMutablePointer.initialize",
    "_copyToContiguousArray", "String.write<A>", "String.+ infix",
    "Sequence.reduce", "Sequence.compactMap", "Sequence.map", "Sequence.forEach",
    "getCharacters", "TargetMetadata<", "getTypeContextDescriptor",
    "outlined consume", "outlined copy", "getEnumTagSinglePayload",
    # Value-copy / destroy plumbing that appears as `outlined init with copy of X`
    # once the `outlined ` modifier is stripped.
    "init with copy", "consume of ", "destroy of ", "DefaultStringInterpolation",
    # Allocator / array / dictionary storage plumbing (round-44 review #2):
    "_xzm_reclaim", "_ArrayBuffer", "consumeAndCreateNew", "Array.init",
    "ContiguousArrayStorage", "allocateStringStorage", "getCharacters",
    # Round-44 review 3: remaining copy/grow/allocate plumbing.
    "UnsafeMutableBufferPointer", "UnsafeMutablePointer.initialize", "initializeWithCopy",
    "_makeUniqueAndReserveCapacity", "Array.reserveCapacity", "_copyCollectionToContiguousArray",
    "_copySequenceContents", "Sequence._copySequenceContents", "_NativeSet", "_xzm_",
    # Round-44 review 4: generic-sequence/pair plumbing and CF/String bridges.
    "Sequence.flatMap", "Collection.map<", "_realloc", "_CFRelease", "CFAllocatorDeallocate",
    "_StringObject.sharedUTF8", "_forceBridgeFromObjectiveC", "String.init(decoding",
    "Array._getElement", "Array.subscript.getter", "Array.+=",
    "_unconditionallyBridgeFromObjectiveC", "_conditionallyBridgeFromObjectiveC",
    "xrealloc", "NSLock.__allocating_init", "dealloc]", "_UnsafeBitset",
    "MutableCollection<>.sort",
    "allocateStringStorage", "mach_absolute_time", "_DictionaryStorage",
    "swift::TargetMetadata", "swift::metadata", "swift::_dynamicCast",
    "Array.append", "Array._reserveCapacity", "Set.insert",
)

RUNTIME_PREFIXES = (
    "swift_", "DYLD-STUB", "_platform_", "xzm_", "malloc", "free",
    "dyld", "libsystem", "std::__1", "operator new", "operator delete",
    "objc_", "_objc_", "os_", "_os_", "spinlock", "pthread", "dispatch_",
    "swift_allocObject", "__swift", "outlined init", "outlined destroy",
    "protocol witness", "specialized _ArrayBuffer", "ContiguousArrayStorage",
    "_StringGuts", "String.", "Substring", "_HashTable", "__RawDictionary",
    "_NativeDictionary", "Dictionary.", "Set.",
)


# Closed-world consumer whitelists (round-44 review 5): chasing individual
# runtime symbols never terminates, so a consumer is now the nearest frame that
# belongs to a KNOWN product module, the bench harness, or the find bar.
# Everything else is mechanical by construction; a stack with no whitelisted
# frame is reported as `<unattributed>` instead of being blamed on plumbing.
PRODUCT_PATS = (
    "ConversationPresentationModel", "ConversationPresentationHandle", "ConversationTimeline",
    "ConversationTimelineEntry", "ConversationProjection", "ConversationActivity",
    "ConversationSearch", "ConversationProcessFold", "ConversationTranscript",
    "ToolVisibilityProjection", "ActivityNarrativeProjection", "ActivityNarrativeSnapshot",
    "ActivitySummary", "CommentaryDerivation", "NarrativeTextCache", "NarrativePhaseScan",
    "DisplayMemoBox", "KimiMessage", "KimiConversation", "KimiPart", "KimiEvent",
    "KimiHistoryBatch", "KimiInFlight", "Presentation.parents", "Presentation.foldParents",
    "presented(activity", "displayMessages", "collapsedWhitespace", "AppLanguage",
    "RowProjection", "TurnSummary", "SummaryProjection", "RenderedSourceCache",
    "ConversationPrefixCache", "ConversationEntryCache", "ConversationExport",
)
HARNESS_PATS = ("benchR43Profile", "benchStreamingDelta", "ProtocolTests", "stamp")
FINDBAR_PATS = (
    "ConversationSearch", "NSDataDetector", "CoreNLP", "MeCab", "DDScanner", "DDLookup",
    "DDLexem", "DDCaching", "_DD", "unorm2", "ucptrie", "NL" "StringTokenizer", "utext",
    "ubrk", "__btrie", "ReplyDocument", "_fetchNextToken", "_FillNextTokenInCache",
    "u_count" "Char32", "CFStringFind", "CFStringFold",
)

VALUE_OP_PREFIXES = (
    "outlined ", "destroy for ", "initializeWithCopy for ", "assignWithCopy for ",
    "assignWithTake for ", "consume of ", "destroy of ", "value witness",
    "protocol witness", "specialized destructiveProjectEnumData",
)

def is_value_op(frame):
    return frame.startswith(VALUE_OP_PREFIXES) or "deinit" in frame

def category(frame):
    if is_value_op(frame):
        return None
    if any(p in frame for p in HARNESS_PATS):
        return "harness"
    if any(p in frame for p in FINDBAR_PATS):
        return "findbar"
    if any(p in frame for p in PRODUCT_PATS):
        return "product"
    return None

def is_decode(fr):
    return any(any(p in f for p in DECODE_PATS) for f in fr)


MODIFIER_PREFIXES = ("specialized ", "static ", "outlined ", "merged ")


def unmodified(frame):
    """Strip non-identifying symbol modifiers so the mechanism rules see
    `Dictionary.subscript.setter` / `protocol witness ... String` instead of
    `specialized Dictionary.subscript.setter` (round-44 review finding: the
    raw startswith() test let a whole class of runtime frames through)."""
    name = frame
    while True:
        for prefix in MODIFIER_PREFIXES:
            if name.startswith(prefix):
                name = name[len(prefix):]
                break
        else:
            return name


def is_mechanism(frame):
    if frame.startswith("0x") or frame == "<deduplicated_symbol>":
        return False  # unresolved: never claim it as a consumer
    if category(frame) is not None:
        return False
    # Match BOTH the raw symbol and the modifier-stripped one: stripping
    # `outlined `/`specialized ` must not disable rules written against the raw
    # spelling ("outlined consume", "specialized _ArrayBuffer"), and the
    # stripped form is what exposes `Dictionary.` / `protocol witness ... String`
    # (round-44 review rounds 1 and 2).
    names = (frame, unmodified(frame))
    if any(p in n for n in names for p in MECHANISM_PATS):
        return True
    if any(p in n for n in names for p in RUNTIME_HELPER_PATS):
        return True
    return any(n.startswith(RUNTIME_PREFIXES) for n in names)


def consumer(fr):
    for frame in fr:
        if frame.startswith("0x") or frame == "<deduplicated_symbol>":
            return "<unresolved-system>"
        cat = category(frame)
        # `ConversationSearch` is both the find-bar entry point and a product
        # module; keep it selectable so detector internals do not become the name.
        if cat in ("product", "harness") or "ConversationSearch" in frame:
            return frame[:110]
    for frame in fr:
        if category(frame) == "findbar":
            return frame[:110]
    return "<unattributed>"


def main():
    path = sys.argv[1]
    targets = sys.argv[2:] or ["utf16-bridge", "arc-copy", "cf-match", "teardown"]
    rows = load(path)
    frames = [fr for _, fr in rows]
    free = [fr for fr in frames if not is_decode(fr)]
    n = len(free)
    print(f"total={len(frames)} decode-free={n}")

    per_bucket = defaultdict(Counter)
    totals = defaultdict(Counter)
    for fr in free:
        bucket = classify(fr)
        if bucket not in targets:
            continue
        c = consumer(fr)
        per_bucket[bucket][c] += 1
        totals["ALL"][c] += 1

    for bucket in targets:
        counts = per_bucket[bucket]
        subtotal = sum(counts.values())
        print(f"\n== bucket [{bucket}] n={subtotal} ({100.0*subtotal/n:.2f}% of decode-free) ==")
        for name, c in counts.most_common(18):
            print(f"  {c:5d} {100.0*c/max(subtotal,1):6.2f}% of bucket | "
                  f"{100.0*c/n:5.2f}% of decode-free  {name}")

    print(f"\n== union of target buckets ==")
    for name, c in totals["ALL"].most_common(25):
        print(f"  {c:5d} {100.0*c/n:5.2f}% of decode-free  {name}")


if __name__ == "__main__":
    main()