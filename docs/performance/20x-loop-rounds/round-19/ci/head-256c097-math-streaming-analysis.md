# CI forensics: run 43662570360 @ 256c097 (superseded head) — math + streaming failures

Run 43662570360 @ 256c097 had **two independent primary failures** plus one
downstream aggregator failure (review F3-NB record correction):

1. "Native math performance regression" — `Unclosed delimiter performance
   regressed` (section 1);
2. "Native session regression (streaming)" — dashboard fixture timeout
   (section 2);
3. "Native build and interaction regression" — aggregator of the two
   (`{"math": "failure", "acceptance": "failure"}`), no independent signal
   (section 3).

Both primaries are attributed to the **known shared-runner noise families**
at HYPOTHESIS strength on the evidence available at 256c097 (comment-only
executable-source delta — which does NOT independently prove identical code
generation or layout — plus prior green at 2f65eeb and overlapping timing
swings); the attribution was subsequently **confirmed empirically**: the
final head 7518f45, whose product tree is identical to 256c097 (= v2
1f9b5d4), passed BOTH gates and the whole run 15/15 green (run 43664396778).
Zero gate changes, zero product reverts, per protocol. The round-19
re-reviewer independently recomputed the same math values from the retained
artifact (baseline [4.94525, 4.36225, 8.398708] ms, candidate [4.548333,
7.765958, 8.467583] ms, median ratio 1.570387 vs the 1.25 limit at
scripts/run-math-performance.py:57-61) — zero mismatch with section 1.

## 1. "Native math performance regression" — `Unclosed delimiter performance regressed`

Gate (scripts/run-math-performance.py:61): median-of-3 ratio of
`unclosed_4096` parse medians, candidate/baseline, limit 1.25, 3-CPU shared
runner. Recomputed from the retained artifact (macos-results-native-math,
round order B1, C2, C3, B4, B5, C6):

| measurement | baseline rounds (ms) | median | candidate rounds (ms) | median | ratio |
| --- | --- | --- | --- | --- | --- |
| **unclosed_4096 (gated)** | 4.9452 / 4.3622 / **8.3987** | 4.9452 | 4.5483 / **7.7660** / **8.4676** | 7.7660 | **1.5704** (>1.25) |
| unclosed_1024 | 1.8599 / 1.0285 / 1.2150 | 1.2150 | 1.2305 / **2.4516** / 1.5503 | 1.5503 | 1.2760 |
| unclosed_256 | 0.3144 / 0.2704 / 0.3574 | 0.3144 | 0.2819 / 0.4639 / 0.3066 | 0.3066 | 0.9751 |
| plain | 7.9492 / 4.1060 / 10.2436 | 7.9492 | 5.5331 / 6.0281 / 3.7878 | 5.5331 | **0.6961** |
| ordinary_backslashes | 4.2727 / 4.6149 / 5.0251 | 4.6149 | 3.3570 / 4.0321 / 3.9790 | 3.9790 | **0.8622** |
| reply | 2.3236 / 2.8077 / 6.5227 | 2.8077 | 3.0862 / 2.4842 / 2.3392 | 2.4842 | **0.8848** |

Noise signatures (same family as rounds 9/12/14/16/17):

1. **~1.9x within-variant round swings on BOTH sides**: baseline 4.36→8.40,
   candidate 4.55→8.47 (unclosed_4096); the baseline's own outlier round
   (8.3987) nearly equals the candidate's worst (8.4676). The gate tripped
   because 2 of the candidate's 3 rounds landed in the contended state while
   the baseline's median excluded its outlier.
2. **Every non-gated parse measurement shows the candidate FASTER**
   (0.70–0.98) — direction opposite to a regression.
3. **The product delta 2f65eeb→256c097 is comment-only**
   (`git diff fe17ef1..1f9b5d4 -- Sources` = comment lines in ReplyMath.swift)
   and 2f65eeb passed this exact gate 15/15 green hours earlier. Note
   (review F3-NB): a comment-only source delta does NOT by itself prove
   identical code generation or binary layout — this point is supportive
   context, not the load-bearing evidence; the load-bearing evidence is the
   empirical one below.
4. Runner contracts self-describe `cpu_count: 3` shared; the gate script
   itself documents "Shared-runner A/A timing differences cannot establish a
   source regression."

Handling per round-17 precedent: the superseded head was not rerun; the
final head 7518f45's own run decided — **15/15 green including this math
gate on the identical product tree**, which is the direct empirical
confirmation of the noise attribution (stronger than any codegen argument).
Quiet-machine retest was not needed: the unchanged gates passed at the final
head (round-17 3ac42fb precedent: identical product bytes green ⇒ no
retest, no rerun).

## 2. "Native session regression (streaming)" — dashboard fixture timeout

Precise identification (review F3-NB): the timed-out fixture is the
**dashboard** mode run INSIDE the streaming group — `"mode": "dashboard"`,
`"capture": "none"`, `"failure": "recording or fixture timed out;
incomplete trace is not acceptance"`, `elapsed_s: 135.08`,
`behavior_passed: false` (streaming-timeout-256c097.log:467-496). With
capture "none" this is a fixture/recording timeout, not proof of a recorder
crash. Same GUI-timeout family as round-12 (acceptance streaming 120s) and
round-13 (six GUI flakes incl. dashboard recording). The v2 diff contains
no AgentWorkbench/GUI change (Sources/AgentWorkbench zero-diff across the
whole PR); 2f65eeb passed the same job green; 7518f45 (identical product
tree) passed it green again — the empirical confirmation. Handling:
superseded head, no rerun needed there; the final head's green run decides.

## 3. "Native build and interaction regression" — aggregator

Aggregated `{"math": "failure", "acceptance": "failure"}` from the two jobs
above; no independent signal.
