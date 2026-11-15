# Screening v1 (flawed base design) — superseded by screening-v2

v1 ran the baseline from the PRISTINE base tree (no tests patch) because the
new contract-assertion pin cannot pass on the unfixed product. That was right
for checks but wrong for bench isolation: the v1 timing trees differed by
tests AND product bytes (tests change: +80/-15 lines; 107 was the product
commit's total added lines across both files), so the v1 token2000_total
signal (Linux +1.026759% 3/3, Mac per-pair +1.813333..+4.024497% 3/3
separated) carries a tests/layout confound RISK. The signal did not
reproduce under the tests-aligned v2 screening or the formal runs; the
causal split between layout confound and run noise remains HYPOTHESIS (no
disassembly-level forensics; review F4 discipline: unchanged source does
not prove unchanged generated instructions).
v2 re-ran both sides tests-aligned (formal A/B template design); the
token2000_total signal vanished on both platforms.

The v1 Linux screen-linux.sh original was overwritten by the v2 revision in
the workspace; the v1 Mac job script is preserved here (screen-mac-v1.sh)
and the v1 driver logs (screen-linux-driver.log; Mac v1 log excerpt in the
round report) document the runs. v1 binaries: base 5bbfd58e (pristine),
cand dc6b16db (identical to v2 candidate — the cross-run control fact cited
in the report).
