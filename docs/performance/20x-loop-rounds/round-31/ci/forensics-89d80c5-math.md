# CI forensics — 89d80c5 (docs-only review-disposition commit), math gate failure

**Signature**: "Fourfold unclosed input grew too quickly" (growth gate; contracts
variant itself `passed`). Aggregate job `Native build and interaction regression`
failed only via MATH_RESULT=failure; all 8 other groups success.

**Decisive same-input evidence (round-30 512c8ae precedent pattern)**:
- failed run (43930481274, head 89d80c5): source_input_sha256 =
  `c5c03c8b0e620f1e0944cfba12d4d129a522fdf7c6074974c986004ec2bd32f0`,
  baseline binary `017cdc4ea0c0f81d60ce366b4fcc16d6b21a8515a4843c072c60efb049e3365b`
- green run (43926658658, head 761ff5f, 15/15 pass): **identical**
  source_input_sha256 `c5c03c8b…` and **identical** baseline binary hash `017cdc4e…`
- diff 761ff5f→89d80c5 is docs-only (6 files under docs/) — product tree
  byte-identical, so the gate input cannot have changed (hashes confirm).
- the same source hash `c5c03c8b` also PASSED the round-30 quiet-machine retest
  (0.9479/1.0061) and the final merged round-30 CI run (dcdf9df, 15/15).

**Green-run unclosed ratios for reference** (thresholds run near noise band):
- parse_unclosed_256: ratio 0.9754, baseline_median_ms 0.2816
- parse_unclosed_1024: ratio 1.8426, baseline_median_ms 1.1080
- parse_unclosed_4096: ratio 1.5808, baseline_median_ms 3.8135
- parse_reply: ratio 2.6707, baseline_median_ms 2.8229

**Classification**: environment nondeterminism — growth-gate variance family on a
loaded runner (22nd recorded instance of environment nondeterminism; first with
identical source AND identical baseline-binary hashes green in the immediately
preceding run of the same PR).

**Action**: same-head `gh run rerun 43930481274 --failed` (protocol step 4);
no quiet-machine retest needed (docs-only; identical-input green receipts above).

