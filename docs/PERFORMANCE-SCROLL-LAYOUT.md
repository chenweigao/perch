# Scroll layout follow-up

Base: `1a036a1`. This is a candidate reduction of repeated layout work, **not acceptance of Codex-like smoothness or a 3× speedup**.

The AppKit clip notification now schedules the existing coalesced viewport pass. The redundant SwiftUI scroll-position callback is removed. Document layout/frame hooks do not force synchronous row traversal for unchanged geometry. A pass with unchanged visible row range and valid geometry skips hosting measurement/frame writes. Content, width and height changes invalidate this shortcut.

All entry types cache measured heights. Content/appearance updates and disclosure actions invalidate measurements; committed SwiftUI geometry updates replace measurements for asynchronously resized local content such as images. Speculative widths and stale content generations cannot overwrite the committed cache.

A 160 pt eager mounting buffer was tried and removed: the initial comparison did not demonstrate a benefit. No preloading, scroll-speed changes or custom inertia are included in the retained candidate.

## Short checks

Same production components/Core/dependencies, 200 mixed-content turns, eight cached sessions. Each complete run first traverses every turn, then executes 1,200 steps of 12 pt through already-read history. Each step includes the application layout/display/transaction flush. This excludes hardware input delivery, compositor presentation, network and the real workspace store. Builds and timings ran separately.

| Run | Warm median ms | Warm p95 ms | First-read p95 ms |
| --- | ---: | ---: | ---: |
| before-small-1 | 0.648 | 2.525 | 50.92 |
| final-small-1 | 0.517 | 2.122 | 39.53 |
| final-small-2 | 0.655 | 2.570 | 40.40 |
| before-small-2 | 0.628 | 2.304 | 40.14 |

The two-run averages are a small change within observed run-to-run variation, not a demonstrated substantial improvement. First-read work remains a visible limitation. All four completed runs observed all 200 turns and the final entry, with identical 105,305 pt document height. Neither warm run in either variant exceeded 16.7 ms; this does not certify end-to-end frame delivery.

One intermediate candidate process exited with SIGKILL and no report. Its cause is unconfirmed and it is recorded as a failed execution, not a timing result. A retry of the same binary completed. The final candidate completed both runs; no long soak was attempted.

Raw compact results, including rejected/intermediate candidates and the missing-report failure, are in [the evidence folder](performance/2026-09-21-scroll-layout/). The final candidate uses the same fixture hash as the small-step baseline; the original buffer trial used the original 240-step wide-jump fixture. Do not compare those different warm-scroll scenarios as a speedup.

Reproduce after building `scripts/build-navigation-preview.sh`:

```sh
NAVIGATION_SCROLL_STEP_POINTS=12 python3 scripts/run-navigation-check.py reading --output .local/scroll-check --switches 8
```

Interaction regression uses the isolated Reading Preview: thinking stream over history, expand/collapse, narrow width, local image task loading, and return-to-latest. Formal remote sessions are not modified.


## Validation

Release App build/signature, WorkbenchChecks, ConnectionChecks, scoped localization and 17 publication tests passed. The first full build rejected cloned precompiled modules carrying the old worktree path; clearing only this worktree's generated module cache and rebuilding succeeded.

The isolated native Reading Preview was exercised through real UI controls: asynchronous local TIFF loading enlarged the image row and moved following thoughts; narrow-column resizing rewrapped text and resized the image; live and historical thinking disclosures and a tool disclosure expanded without overlap. While thoughts appended every 100 ms, scrolling upward over the preview entered history and kept the scrollbar at 0.944595 on the later check. Return-to-latest restored the live preview. This verifies those interaction paths, not a comparative subjective smoothness result.
