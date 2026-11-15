# Round-22 v2 probe record: CJK compatibility ideograph folding (review F1)

Probe source: compat-decomposition-probe.swift, run 2026-11-15 on both
toolchains (interpreter mode — semantics only): Linux Alibaba Cloud Linux 3
/ Swift 6.3.3 and macOS arm64 / Apple Swift.

| probe | Linux | macOS |
| --- | --- | --- |
| `decomposedStringWithCanonicalMapping` of U+FA55/U+FA8E/U+F96A/U+2F00/U+2F800 | SELF (no decomposition exposed) | SELF (no decomposition exposed) |
| `"冲\u{FA55}".contains("冲突")` | **true** | **true** |
| `"\u{FA8E}\u{7D22}".contains("搜索")` | **true** | **true** |
| lowercased-chain contains | true | true |
| decomposing scalars in U+F900–FAFF via the Foundation API | 0 | 0 |

Findings:
1. The canonical folding of compatibility ideographs happens INSIDE the
   canonical substring search on both platforms; Foundation's public
   decomposition API does not expose the singleton mappings. A
   decomposition-API-based completeness sweep is therefore impossible —
   the shipped pin uses an OPERATIONAL canonical-equivalence sweep
   (String's canonical == / Set<String> membership) instead.
2. The operational sweep over all 1,112,064 scalars finds exactly THREE
   scalars canonically equal to a CJK keyword character besides the
   characters themselves: U+FA55 (→突), U+FA8E (→搜), U+F96A (→索) —
   matching the reviewer's counterexamples exactly. All three lie in
   U+F900–FAFF, inside the detected EF A4..AB byte range.
3. Both platforms fold identically for these cases, so the compat routing
   (whole text → legacy chain) reproduces legacy behavior on both; the
   differential pin still compares same-platform because the legacy
   predicate itself is platform-divergent under GB9b (round-17 record).
