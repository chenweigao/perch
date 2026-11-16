# Round-29 sizing probe: NSDataDetector byte pre-guard — DOA

Temp probe (uncommitted, reverted; method: env-gated counters in
RenderedSourceCache.rendered produce path, R29_PROBE=1 WORKBENCH_BENCH=streaming,
Linux, tree=1753216+probe):

- uniques=6741 (=963 unique sources x 7 fresh-cache instances per bench run),
  bytes=22,056,587
- Simple guard (no "http" case-insensitive AND no "."): skipped=1792 (26.58% count)
  but skippedBytes=805,812 = **3.653% of bytes** — dot-free sources are the small ones.
- Optimistic TLD-style guard proxy (skip unless "http" or dot followed by 2-6 ASCII
  letters): skipped bytes 813,386 = **3.688%** — virtually identical; ".swift"-style
  extensions are TLD-shaped, so almost every dotted source still admits.
- http=0 across all uniques (bench corpus contains no URLs); dotOnly=4949.

Conclusion: detector-call avoidance via byte guard caps at ~3.7% of rendered BYTES;
with detector ~66.6% of render (round-16 attribution) and render ~490ms of Mac cold
637ms, the ceiling is ~1.6% of cold — at/below the noise band (1.3-1.7%), before any
DD-behavior proof burden. INDEX round-17 postnote additionally marks detector
internals a DE-FACTO RED LINE (detection output is the behavior contract).
Real-world corpora contain more URL/dot content -> even lower share.
**DOA by sizing; do not commit a round** (round-27 prep ASCII-successor precedent).
Probe binaries never used for adoption numbers.
