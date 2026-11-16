# Round-31 attribution first-attempt artifact (disclosed, discarded)

The first r31-attr job shipment raced with a same-name reship: the runner
consumed the UNFIXED job (cold loop injected only a fresh RenderedSourceCache;
entryCache defaulted to .shared) before the corrected file replaced it. Result:
the "cold" xctrace record profiled iterations 2..N of the shared-entry-cache
warm shape — both XMLs are warm-shaped (DD/langid frames ~60 catalog refs,
zero dominant sampling; region profiles of the two files near-identical),
and the results log captured only "exit=0" (same-name job race).

Evidence for the diagnosis: (a) local Linux reproduction of the FIXED harness
on a378a9c shows cold=338.4ms / reopen=46.75ms (correct 7.2x separation);
(b) both fetched XMLs classify identically (cache-mgmt ~19%, timeline-make
~18%, verify ~7-8%, cf-match ~2.5%, display-serialize <0.5%, render ~0.1%);
(c) rows-with-bench-frame counts 5,600/5,634 confirm the bench loop (not the
checks suite) ran, but in warm shape.

The first-attempt XMLs (.local/round31/xml/) are RETAINED as artifacts of the
warm shape only and must NOT be used as the cold-shape attribution. Clean
rerun shipped as r31b-attr (distinct name, fixed harness verified in the
shipped file at the line level).
