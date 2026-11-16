# CI failure at ded7625 (run 43908333878): Native navigation regression (interaction)

- Failing check: navigation-disclosure-full, exit 1 after 11.0s (not a timeout).
- Failure detail (artifact disclosure-failure.json): iteration 0, kind
  "Thoughts", "wrong final Thoughts height: 28.0, collapsed 28.0" — expanded
  height equals collapsed height (the disclosure expansion did not take
  effect within the GUI wait window).
- Other six navigation checks in the same job PASSED (streaming-rendering,
  tool-card, fast-scroll, turns, roundtrip, disclosure).
- Isolation: ded7625 (v5) product delta vs 429d476 = ConversationEntryCache
  admission-cost arithmetic only (JSONValue size walk at store time). The
  navigation disclosure path does not construct ConversationSearch and never
  touches the entry cache; a cost-arithmetic change cannot alter disclosure
  heights semantically. The same check passed at 429d476, 9c90f6f (15/15) and
  across round-29 heads.
- Classification: GUI animation/shared-runner jitter family (round-12
  precedent: reading-design/math-app/acceptance-streaming GUI failures judged
  runner jitter with forensics; ded7cf1 GUI pair same family this round).
  A code-layout channel (v5 shifts WorkbenchCore layout) cannot be excluded
  per round-24 F4 wording but has no semantic mechanism; HYPOTHESIS either
  way, gates never modified.
- Disposition: same-head `gh run rerun --failed`.
