# Round-43 evidence notes / disclosures

- **XML not in repo**: the Mac Time Profiler trace (`streaming-time-profile.xml`, ~13.5MB)
  stays in `.local/round43/` per the round-15/41 precedent; `attr/streaming-attribution.txt`
  and `attr/decode-free-composition.txt` are the derived deliverables (analyzer:
  `attr/analyze_r43.py`, round-35/36/38/41 lineage).
- **No A/B batch**: zero product bytes this round (`git diff 127d3198 7e47ce56 -- Sources/`
  = 0 lines). Product bytes remain round-42 v2 (`2baedac7`); test-byte changes (pin
  strengthening) do not trigger the dual-platform six-pair protocol because the measured
  product binaries are unchanged.
- **Harness fidelity correction**: this job calls `displayMessages` twice per cycle
  (cold then warm) to mirror the product's multi-caller shape; r41-attr called it once.
  Reported fidelity ratio improves from 1.25 (r41) to ~1.0 against the bench components
  (commentary 0.4383 + find 0.271 + model.update).
- **Sanitization**: personal paths and embedded email addresses redacted per the
  commit-hook contract (`/home/<dev>`, `/Users/<mini>`, `<redacted-email>`). No real
  session data, no remote connections.