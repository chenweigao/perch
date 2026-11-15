# CI forensics: run 43696550735 @ e6af380 — math gate failure (typeset-32)

Failed gate: "Typeset/draw regression exceeds 15% at 32"
(scripts/run-math-performance.py, best_ratio limit 1.15). The companion
"Native build and interaction regression" job is the aggregator of this
failure (no independent signal).

## Recomputed from the retained artifact (macos-results-native-math, round order B1, C2, C3, B4, B5, C6)

typeset-32 totals (cold_attachment.total_ms + first_light_dark_draw.total_ms):

| variant | round 1 | round 2 | round 3 | round 4 | round 5 | round 6 |
| --- | --- | --- | --- | --- | --- | --- |
| baseline | 114.33 | — | — | 82.44 | 66.59 | — |
| candidate | — | 99.62 | **193.90** | — | — | 82.10 |

- best_ratio = 82.10 / 66.59 = **1.2330** (> 1.15 → fail); medians 82.44 vs 99.62.
- **Within-variant swings: baseline 1.72x (66.59→114.33), candidate 2.36x
  (82.10→193.90)** — the candidate's round-3 outlier (193.90, 2.4x its own
  best) drives its median above the baseline's.
- The candidate's BEST (82.10) is statistically indistinguishable from the
  baseline's MEDIAN (82.44).

## Noise-family attribution (rounds 9/12/14/16/17/20 lineage)

1. Swing signature matches (documented family range 1.4–2.2x; this run
   1.72x/2.36x) on the self-described 3-CPU shared runner.
2. The measured surface — SwiftMath typeset/draw of 32 formulas — has **no
   call-path relationship** with this PR's only product change
   (ActivityNarrative phase scan; math rendering goes through ReplyMath /
   MathRenderer / SwiftMath and never touches ActivityNarrativeProjection).
3. The same gate on the same runner passed at every head of the three
   immediately preceding PRs (#341: 2f65eeb/7518f45/d7c0cd0; #342:
   f4025c0/db29f68; #343: 48bbceb/89f676d), with zero product changes to
   any math-path code since.

## Handling (round-16 precedent: new product bytes without a prior CI math green)

Quiet-machine retest on the Mac mini via PerfRunner (Aqua session), real
gate script `scripts/check-math-performance.sh` with
`WORKBENCH_MATH_BASELINE_REF=ed53341` (the PR base), head e6af380:

**RESULT: status=passed** (math-retest-e6af380.log, math-retest-summary.json):

| variant | CI failed run best_ratio | quiet retest best_ratio | quiet ratio |
| --- | --- | --- | --- |
| typeset-32 (the failed gate) | **1.2330** (>1.15) | **1.031** | 1.106 |
| typeset-128 | pass | 1.0021 | 1.002 |
| typeset-512 | pass | 0.9926 | 0.9805 |
| parse_* (8 variants) | pass | — | 0.9472–1.0206 |

Same signature as the round-14 (CI 1.2672 → quiet 0.9701) and round-16
(CI 1.2791 → quiet 1.0077) precedents: the identical product bytes pass
the real gate on the quiet machine. Noise attribution empirically
confirmed; the failed jobs were rerun at the SAME head (zero gate changes,
zero product reverts), per the documented protocol — **rerun result:
15/15 green at e6af380**, closing the forensics loop. (Note: e6af380 was
subsequently superseded by the review-F1 compatibility fix; this record
stands for the head it measured.)

Retest harness note: the first retest attempt exited 2 on the
build-preview fresh-directory guard — math-preview build directories left
over from earlier rounds' retests are gitignored, so the job's
`git clean -fdq` did not remove them; the job now removes
`.local/math-performance-sources` and both `build/Math Performance *.app`
trees explicitly before running (disclosed as a harness artifact, both
attempts logged).
