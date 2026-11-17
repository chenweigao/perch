# Round-41 evidence notes / disclosures

- **XML not in repo**: the Mac Time Profiler trace
  (`streaming-time-profile.xml`, ~60MB) stays in `.local/round41/` per the
  round-15 precedent; `attr/streaming-attribution.txt` and
  `attr/decode-free-composition.txt` are the derived deliverables
  (analyzer: `.local/round41/analyze_r41.py`, round-35/36/38 lineage,
  zero-deviation validated on prior rounds).
- **Invalid Mac batch v1**: `ab/r41-ab-v1.job` ran with HEAD_cand ==
  HEAD_base == dade949f because candidate commit e1b7c29e had not been
  pushed and the detached checkout failed silently (`set -u` without
  `-e`). Discarded; `ab/r41-ab-v2.job` adds full-SHA checkout assertions
  and a fixture-hash equality gate. The invalid batch's PerfRunner log
  (HEAD lines) is the evidence; its 60 bench logs are not staged.
- **Portable dirty=true**: untracked round artifacts (report skeleton,
  `.local/`) at run time; tracked tree clean at e1b7c29e. 10/10 checks
  exit 0.
- **Debug-sentinel load episode**: sentinel runs 1–9 (debug binaries)
  coincided with a high-load window on the Linux host (chain_total
  1.16→3.4ms absolute drift; two ~130% CPU unrelated processes).
  Absolute values from that window are used only for within-batch
  alternation comparisons; the release sentinel (runs 10–12) and the
  formal Linux batch ran at load ~1.1–1.4 with normal absolutes.
- **Debug-vs-release sentinel disclosure**: runs 1–9 used debug builds,
  which over-penalize the derivator's generic/closure-heavy code
  (stdlib/Foundation calls stay optimized in debug builds while product
  code does not). Formal batches on both ends use `-c release`.
- **Battery m4 equivalence**: the detail-nonempty gate mutant is
  EQUIVALENT (unkillable): once a delimiter is committed, the trimmed
  view's last byte is non-trim, so the suffix always retains a non-trim
  byte (`nonEmpty` structurally true). Replaced by m4b (headline≤48
  gate drop), which died. Recorded in the report's battery table.
- **Battery script defect (self-reported)**: first battery run's
  BUILD-FAIL path skipped the pristine restore, cascading m9/m10 onto
  m8's broken source; fixed (restore-before-mutate + restore-on-fail)
  and the four affected mutants rerun in `battery/run-battery-fix.sh`
  output. All deaths verified with killer lines.
- **Sanitization**: personal paths and embedded email addresses
  redacted per the commit-hook contract (`/home/<dev>`, `/Users/<mini>`,
  `<redacted-email>`). No real session data, no remote connections
  touched; benches are synthetic fixtures.
