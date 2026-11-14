# Round-16 screening #1 (Mac mini, 2026-11-14) — search-haystack materialization REJECTED

Candidate: materialize `ConversationSearch` Entry's joined search haystack
(`rendered.joined(separator:) as NSString`) as contiguous UTF-16 storage
instead of the lazily bridged Swift String wrapper, so `NSString.range(of:)`
(CF locale matching) reads a buffer directly.

Motivation: the cold find-bar attribution (21,067 samples) showed a
utf16-bridge region of 20.08% non-setup with `String.UTF16View._nativeGetIndex`
8.51% of all samples. (A later call-site attribution — see screening #2 —
showed 98% of that leaf actually sits under NSDataDetector linkMatches, not
the query match loop; this screen had already independently rejected the
haystack variant.)

Variants (package `haystack-materialization-screen/`, run log
`haystack-materialization-run-mac.log`):
- v0 = `s as NSString` (product current, lazy __StringStorage bridge)
- v1 = `NSString(string: s)`
- v2 = `CFStringCreateWithCharacters` copy (contiguous UTF-16; round-trip
  probe: re-bridging returns `__NSCFString`, materialization survives)
- v3 = `NSMutableString(string: s)`

Equivalence: PASS — identical `[NSRange]` match lists, excerpts
(rangeOfComposedCharacterSequences-aligned ±50/+80 windows) and `.length`
over 77 texts (64 fixture-shaped corpus runs + 13 adversarial: NFD, ZWJ
emoji, combining sequences, CRLF between hits, dense-hit, empty) × 5 queries
× 3 variants = 1,155 comparisons; case-sensitive option parity also PASS.

Timing (SwiftPM release, 9 alternating blocks, medians):

| query | metric | v0 | v1 | v2 | v3 |
| --- | --- | --- | --- | --- | --- |
| 已经处理 (CJK, product-representative) | corpus64 ms/sweep | 2.865 | +21.7% | **+19.2%** | +13.7% |
| 已经处理 | big120KB ms/search | 2.860 | +21.8% | **+19.7%** | +13.5% |
| inspect (ASCII) | corpus64 | 1.326 | -3.9% | **-9.3%** | -22.6% |
| inspect | big120KB | 1.333 | -7.2% | **-11.4%** | -25.0% |

**Decision: REJECTED — do not open a round.** For the CJK query every
materialization variant is 13.5–21.8% SLOWER (for ASCII the all-variant
range is -3.9…-25.0%: v1 -3.9/-7.2%, v2 -9.3/-11.4%, v3 -22.6/-25.0% —
re-review finding 9 corrected an earlier "-9…-25%" summary that covered
only v2/v3). Mechanism (inference): CF keeps
a direct UTF-8 fast path for lazily bridged Swift-native strings (the
`_CFStringGetCStringPtrInternal` leaf in the same traces); forcing UTF-16
storage gives that up, and only the ASCII/DD-lexer-heavy path benefits. The
product's representative queries are CJK (Chinese-first UI), and a
query-script-conditional materialization would poison the per-entry cached
`text` (query-independent by design). Recorded for the negative list:
**haystack materialization is script-dependent — never adopt on an
ASCII-only microbenchmark.**
