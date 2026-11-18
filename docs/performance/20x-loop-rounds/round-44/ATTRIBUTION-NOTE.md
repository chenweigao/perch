# Round-44 attribution notes / disclosures

- **No new trace**: this round reuses the round-43 archived Time Profiler XML
  (`.local/round43/streaming-time-profile.xml`, 13.5MB, not in repo per round-15/41
  precedent). Only the analysis stage is new.
- **Attribution pass 1 (self-reported error)**: the first consumer walk stopped at the
  first frame that was not in a generic leaf bucket, which attributed 60-70% of the four
  target buckets to runtime plumbing (shares of the decode-free denominator n=11,691):

  | nearest non-bucket frame | utf16-bridge | arc-copy | teardown |
  | --- | --- | --- | --- |
  | `RefCounts<...>::doDecrementSlow` | 7.78pp | 6.63pp | 6.93pp |
  | `_ContiguousArrayBuffer._consumeAndCreateNew` | 4.21pp | 4.23pp | — |
  | `_Variant.setValue` | 1.06pp | 1.31pp | — |

  These are mechanism frames even though they are neither leaf buckets nor product code:
  ARC slow paths, array grow/copy, dictionary storage writes, string-storage helpers and
  metadata lookups (`RUNTIME_HELPER_PATS`).
- **Attribution pass 2 (review finding F1)**: `frame.startswith(RUNTIME_PREFIXES)` did not
  strip non-identifying symbol modifiers, so frames already in the exclusion set slipped
  through as `specialized Dictionary.subscript.setter`, `specialized protocol witness ...
  String`, etc. Fixes: strip `specialized `/`static `/`outlined `/`merged ` before rule
  matching; add `init with copy`, `consume of (`, `destroy of `, `DefaultStringInterpolation`;
  isolate `0x...` / `<deduplicated_symbol>` as `<unresolved-system>` (1.09%) instead of
  silently folding them into a consumer.
  Effects: `Dictionary.subscript.setter` no longer appears as its own consumer — 93% of its
  samples resolve to `closure #1 in ConversationPresentationModel.Presentation.parents`
  (277 samples, **2.37%**); `Array.+` corrects from 8.57% to **8.43%**.
- **`Array.+ infix` is not unique to `displayMessages`** (review finding F2). The chain has
  several array concatenations (`Snapshot.presented`, `Model.update`, navigation). Current
  XML split of the 986 samples: **937 (8.01%) under
  `closure #1 in KimiConversation.displayMessages.getter`** and **49 (0.42%) under
  `ConversationPresentationModel.Snapshot.presented`**. The independent review's walk found
  a small third group under `Model.update`; both walks agree the bulk is displayMessages.
- **Cost-reuse scan scope is path-dependent** (review finding F3). `reuseEnd == split` on the
  history-reuse path leaves `[split, count)` (the newest turn) to the deep `==`, while
  `canReuse` verifies the prefix `[0, split)`; on the non-reuse path (`reuseEnd = 0`, e.g.
  prepend) the loop covers `[0, count)` with `shift` only re-aligning indices, i.e. the whole
  window. `projectTurns` additionally calls `sameWindow` per existing turn. The report's
  earlier "≤2%" bound and the claim that the overlap is limited to newly appended messages
  are withdrawn.
- **`cost(_:)` is not the verification cost**: it computes payload length for messages that
  miss reuse (`ConversationPresentation.swift:657-670`); the deep `==` lives in the update
  loop at `:605`. Its 1.88% share must not be read as the dedup ceiling.
- **Rounding**: the four displayed bucket shares sum to 59.66%; the raw union is
  6,974 / 11,691 = 59.6527%. Both are reported; the category totals use the raw value.
- **Analyzer portability**: `attr/analyze_r44_consumers.py` resolves the round-43 lineage
  analyzer from its own file location (`../round-43/attr/analyze_r43.py`, committed in the
  round-43 settle), so it runs from the repository root; regenerating
  `consumer-attribution.txt` with the committed script is byte-identical.
- **Sanitization**: personal paths and embedded email addresses redacted per the
  commit-hook contract (`/home/<dev>`, `/Users/<mini>`, `<redacted-email>`). No real
  session data, no remote connections.