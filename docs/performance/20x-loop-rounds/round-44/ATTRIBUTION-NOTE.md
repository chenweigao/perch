# Round-44 attribution notes / disclosures

- **No new trace**: this round reuses the round-43 archived Time Profiler XML
  (`.local/round43/streaming-time-profile.xml`, 13.5MB, not in repo per round-15/41
  precedent). Only the analysis stage is new.
- **First-pass attribution error (self-reported)**: the initial consumer walk stopped at
  the first frame that was not in a generic leaf bucket, which attributed 60-70% of the
  four target buckets to runtime plumbing:

  | nearest non-bucket frame | utf16-bridge | arc-copy | teardown |
  | --- | --- | --- | --- |
  | `RefCounts<...>::doDecrementSlow` | 7.78pp | 6.63pp | 6.93pp |
  | `_ContiguousArrayBuffer._consumeAndCreateNew` | 4.21pp | 4.23pp | — |
  | `_Variant.setValue` | 1.06pp | 1.31pp | — |

  These are shared percentages of the decode-free denominator (n=11,691), i.e. the same
  runtime helpers across all four buckets. The corrected walk continues past ARC slow
  paths, array grow/copy helpers, dictionary storage writes, string-storage helpers and
  metadata lookups (`RUNTIME_HELPER_PATS` in `attr/analyze_r44_consumers.py`).
  **Lesson**: a "nearest consumer" attribution must define the mechanism set
  exhaustively — runtime helpers are mechanism frames even though they are neither leaf
  buckets nor product code.
- **`Array.+ infix` identification**: the chain has exactly one array concatenation,
  `ConversationTimeline.swift:275` (`messages + [live]` in the displayMessages cold path).
  The other two `+ [` sites in WorkbenchCore are `ConversationPresentation.swift:660`
  (Int + Int) and `RemoteFile.swift:152` / `RemoteGit.swift:86` (not in the bench chain).
  Identification is by symbol + source exclusion, not by call-site instrumentation.
- **decode-free denominator**: round-34 F2 lineage, decode-ancestry 43.64% of 20,743
  samples excluded (harness restart wire-decode, not product cost).
- **Analyzer portability**: `attr/analyze_r44_consumers.py` resolves the round-43 lineage
  analyzer from its own file location (`../round-43/attr/analyze_r43.py`, committed in
  round-43 settle), so it runs from the repository root as documented; regenerating
  `consumer-attribution.txt` with the committed script is byte-identical.
- **Sanitization**: personal paths and embedded email addresses redacted per the
  commit-hook contract (`/home/<dev>`, `/Users/<mini>`, `<redacted-email>`). No real
  session data, no remote connections.