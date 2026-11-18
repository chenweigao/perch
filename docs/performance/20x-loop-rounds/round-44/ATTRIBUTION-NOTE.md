# Round-44 attribution notes / disclosures

- **No new trace**: this round reuses the round-43 archived Time Profiler XML
  (`.local/round43/streaming-time-profile.xml`, 13.5MB, not in repo per round-15/41
  precedent). Only the analysis stage is new.
- **Attribution pass 1 (self-reported error)**: the first consumer walk stopped at the
  first frame that was not in a generic leaf bucket, attributing 60-70% of the four
  target buckets to runtime plumbing (decode-free denominator n=11,691):

  | nearest non-bucket frame | utf16-bridge | arc-copy | teardown |
  | --- | --- | --- | --- |
  | `RefCounts<...>::doDecrementSlow` | 7.78pp | 6.63pp | 6.93pp |
  | `_ContiguousArrayBuffer._consumeAndCreateNew` | 4.21pp | 4.23pp | — |
  | `_Variant.setValue` | 1.06pp | 1.31pp | — |

- **Attribution pass 2 (review round 1, F1)**: `startswith(RUNTIME_PREFIXES)` did not strip
  non-identifying modifiers, so `specialized Dictionary.subscript.setter`,
  `specialized protocol witness ... String` etc. escaped the exclusion set. Fix: strip
  `specialized `/`static `/`outlined `/`merged ` before rule matching; isolate
  `0x...`/`<deduplicated_symbol>` as `<unresolved-system>`; add `init with copy`,
  `consume of (`, `destroy of `, `DefaultStringInterpolation`.
- **Attribution pass 3 (review round 2, F1')**: stripping alone **disabled rules written
  against the raw spelling** — `"outlined consume"` and `"specialized _ArrayBuffer"` no
  longer matched, and `"consume of ("` missed `consume of ToolVisibilityProjection.Split?`.
  Fix: match **both** the raw and the stripped name against every pattern, and add
  `_ArrayBuffer`, `consumeAndCreateNew`, `Array.init`, `_xzm_reclaim`, `consume of `,
  `ContiguousArrayStorage`, `allocateStringStorage`, `getCharacters`. (Superseded by
  pass 4 below; at that stage the union read `Array.+` 8.57% and harness 8.10%.)
- **`Array.+ infix` is not unique to `displayMessages`** (review round 1, F2); the chain
  has several array concatenations. Split of the 1,003 samples (after pass 4):
  **938 (8.02%) under `closure #1 in KimiConversation.displayMessages.getter`,
  49 (0.42%) under `ConversationPresentationModel.Snapshot.presented`,
  16 (0.14%) under `ConversationPresentationModel.update`** (1003 samples, 8.58%).
- **`Dictionary.subscript.setter` concentration**: under pass-2 attribution, 276 of the
  296 setter samples (**93.243%**) belong to
  `closure #1 in ConversationPresentationModel.Presentation.parents`; the parents total is
  277, so one further sample reaches it from another frame. The report quotes the 93%
  figure as the setter concentration, not as "all parents samples".
- **Cost-reuse scan scope is path-dependent** (review round 1, F3): `reuseEnd == split` on
  the history-reuse path leaves `[split, count)` (newest turn) to the deep `==`, while
  `canReuse` verifies `[0, split)` — strictly disjoint half-open intervals; on the
  non-reuse path the **loop range** is `[0, count)` but the **compared set** is limited to
  messages with a corresponding previous index; `projectTurns` runs only when `canReuse`
  failed, and calls `sameWindow` only where an old chunk exists with equal count. The
  earlier "≤2%" bound is withdrawn.
- **`cost(_:)` is not the verification cost**: it computes payload length
  (`ConversationPresentation.swift:657-670`); the deep `==` lives in the update loop at
  `:605`. Raw share 219/11,691 = **1.873% → 1.87%**; the table's 1.88% is the sum of the
  two displayed leaf shares (0.98 + 0.90).
- **Rounding**: the four displayed bucket shares sum to 59.66%; the raw union is
  6,974 / 11,691 = 59.6527% → **59.65%**. Both are reported and labelled.
- **Analyzer portability**: `attr/analyze_r44_consumers.py` resolves the round-43 lineage
  analyzer from its own file location (`../round-43/attr/analyze_r43.py`, committed in the
  round-43 settle), so it runs from the repository root; regenerating
  `consumer-attribution.txt` / `consumer-views.txt` with the committed scripts is
  byte-identical.
- **Sanitization**: personal paths and embedded email addresses redacted per the
  commit-hook contract (`/home/<dev>`, `/Users/<mini>`, `<redacted-email>`). No real
  session data, no remote connections.

- **Attribution pass 4 (review round 3)**: further mechanical frames were still being
  counted as consumers: `UnsafeMutableBufferPointer.initialize` (23),
  `Array._makeUniqueAndReserveCapacity…` (11), `Array.reserveCapacity` (11),
  `_copyCollectionToContiguousArray` (9), `Sequence._copySequenceContents` (6),
  `_xzm_segment_group_span_mark_used` (6), `_NativeSet.resize` (3). All were added to
  `RUNTIME_HELPER_PATS` (plus `initializeWithCopy`, `_xzm_`, `UnsafeMutableBufferPointer`).
  The classifier also gained `benchStreamingDelta` / `ProtocolTests.main()` as harness and
  `unorm2` / `ucptrie` / `NLStringTokenizer` as detector plumbing. Final values:
  `Array.+` **8.58%** (1003), harness category **8.50%**, find-bar **20.13%**, product
  **29.93%**, unresolved **1.09%**.
