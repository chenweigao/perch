# Round-34 harness fidelity record (local dry runs, Linux dev machine)

Protocol: every attribution harness is dry-run locally before shipment
(r31 four-attempt lesson; r33 shipped clean; r34 continued the practice).

## Paging harness — the 7x inflation bug (found by dry run, fixed pre-ship)

- v1 harness (fixture inherited from r33, NO history pre-loop):
  `r34_paging_triple_median_ms=79.881 min=54.610 max=107.146` (4s run,
  100 prepends) — vs bench older_page_full_chain Linux 11.0ms = ~7x inflated.
- Root cause: the bench fixture builds five history turns (`for index in
  -5..<0`) and captures `earlierRaw` BEFORE resetting `raw` for the main
  turns, so prepended pages carry DISTINCT message ids. The r33-inherited
  harness lacked the pre-loop; pages decoded from the main `raw` duplicated
  window ids, sending the projection through a different (dedup-heavy) path.
- Fix: bench-exact pre-loop + earlierRaw; pages per cycle extended 3→20
  (mechanism identical; measurement share 25%→63%; disclosed).
- v2 harness: `r34_paging_triple_median_ms=8.956 min=8.338 max=16.000`
  (4s, 29 cycles/87 prepends); v3 (20 pages): `median_ms=9.061 min=8.334
  max=15.535` (14 cycles/280 prepends) ≈ bench 11.0ms ✓ faithful.

## Streaming harness — passed first dry run

- `r34_chain_median_ms=2.062 min=2.019 max=435.147 find_median_ms=0.514`
  (2s; max=first cold find build, once per run by design — ONE findBar
  across cycles mirrors the bench's warm same-instance query_update shape).
- Bench references (Linux): chain_total 1.30 + find_bar_query_update 0.53
  = 1.83ms vs harness chain 2.06 (harness chain additionally includes
  model.update + memoryKeys + activity in one span) ✓ consistent.

## Shipped job receipts (mini, Aqua)

- Timing context (5s, untraced): paging 39 cycles/780 prepends; streaming
  9 cycles/1,845 updates. Self-reported median lines not captured by the
  job's grep pattern (`r34_profile` prefix vs `r34_paging_triple_median_ms`
  / `r34_chain_median_ms`) — disclosed; bench metrics remain the timing
  authority, cycle/prepend counts confirm both shapes.
- Record: both exit 0, XMLs exported (7.3MB paging / 13.4MB streaming);
  porcelain 0/0/0 (applied=2); binary hash b5caaa8992e89a50…; revert clean.
