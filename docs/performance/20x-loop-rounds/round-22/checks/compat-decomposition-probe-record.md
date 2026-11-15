# Round-22 probe record: CJK compatibility ideograph folding (review F1 + re-review F1' correction)

## Corrected probe (v2, byte-level comparison — authoritative)

Probe source: `compat-decomposition-probe-v2.swift`; run 2026-11-15 on both
toolchains (interpreter mode — semantics only): Linux Alibaba Cloud Linux 3
/ Swift 6.3.3 (`compat-probe-v2-linux.txt`) and macOS arm64 / Apple Swift
(`compat-probe-v2-macos.txt`). **Identical results on both platforms:**

| scalar | bytes changed by `decomposedStringWithCanonicalMapping` | decomposition |
| --- | --- | --- |
| U+FA55 | **YES** | U+7A81 (突) |
| U+FA8E | **YES** | U+641C (搜) |
| U+F96A | **YES** | U+7D22 (索) |
| U+2F00 | NO (Swift reports self) | U+2F00 |
| U+2F800 | **YES** | U+4E3D (丽) |

Byte-changing scalars in U+F900–U+FAFF: **460** on both platforms (matches
the re-reviewer's independent count). `"冲\u{FA55}".contains("冲突")` ==
**true** on both platforms (canonical substring search folds).

## Erratum for the original probe (v1)

The original probe (`compat-decomposition-probe.swift`, kept unmodified as
historical evidence) compared `decomposed == original` with Swift's String
`==` — which is CANONICAL equality and therefore returns true even when the
decomposition changed the scalars. Its "SELF (no decomposition exposed)"
rows and the derived claims ("Foundation's decomposition API does not
expose the singleton mappings", "a decomposition-API-based sweep is
impossible") were **false** and are retracted (re-review F1'). Two
consequences were re-derived:

1. The decomposition API DOES expose the mappings on both platforms; a
   byte-comparison sweep was possible all along.
2. The shipped pin nevertheless remains the OPERATIONAL canonical-equality
   sweep (Set<String> membership over all 1,112,064 scalars), which the
   re-reviewer confirmed valid and which found exactly three keyword
   bridges (U+FA55/U+FA8E/U+F96A). Rationale updated: the operational
   sweep tests the SAME equality the legacy canonical search relies on and
   is independent of decomposition-API behavior across toolchains — it is
   the stronger pin, not a workaround. (U+2F00's self-report above shows
   decomposition-API behavior can surprise; the operational equality is the
   contract that matters.)

Note: U+2F00 (Kangxi radical one) reports no byte change in Swift on both
platforms despite UnicodeData listing a canonical decomposition to U+4E00;
the scanner's E2 BC..BF detection covers the whole Kangxi block
conservatively regardless, and the operational sweep confirms no Kangxi
scalar is canonically equal (in Swift's semantics) to any keyword
character. The re-reviewer independently checked all 29 keyword characters
against Kangxi and supplement equivalents with zero misses.

## Match-folding confirmation (unchanged from v1)

`contains` folds the compatibility ideographs on BOTH platforms, so the
compat-detection → whole-text legacy routing is required on both platforms;
the differential pin compares same-platform because the legacy predicate
itself is platform-divergent under GB9b (round-17 record).
