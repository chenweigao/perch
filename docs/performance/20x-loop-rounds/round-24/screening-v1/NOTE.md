# Screening v1 (flawed base design) — superseded by screening-v2

v1 ran the baseline from the PRISTINE base tree (no tests patch) because the
new contract-assertion pin cannot pass on the unfixed product. That was right
for checks but wrong for bench isolation: the tests bytes (+107 lines) move
the WorkbenchChecks binary layout, and the v1 token2000_total signal
(Linux +1.03% 3/3, Mac +1.8~4.1% 3/3 separated) was confounded by it.
v2 re-ran both sides tests-aligned (formal A/B template design); the
token2000_total signal vanished on both platforms.

The v1 Linux screen-linux.sh original was overwritten by the v2 revision in
the workspace; the v1 Mac job script is preserved here (screen-mac-v1.sh)
and the v1 driver logs (screen-linux-driver.log; Mac v1 log excerpt in the
round report) document the runs. v1 binaries: base 5bbfd58e (pristine),
cand dc6b16db (identical to v2 candidate — the cross-run control fact cited
in the report).
