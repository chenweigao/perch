# Sidebar navigation computation — 2026-09-28

The change removes repeated navigation work from the main thread. It does not
establish a faster end-to-end session switch or zero dropped frames.

- Cache group membership until saved groups change, including for the session
  directory. Cache recent/pinned projection and group shortcuts until their
  catalog, pin, group, filter or selected-group inputs change.
- Build one session lookup for batch group summaries instead of scanning the
  entire catalog for every group. Choose visible shortcuts before computing them.
- Build pinned/recent rows and the attention count in one catalog pass. Preserve
  pin order, the 20-row recent bound, offline/archive semantics and native glass.

## Measured computation

Release `WorkbenchChecks`, same-process alternating old/new calls, 11 samples
per size. Both paths must return identical summaries on every sample. The old
path uses the unchanged single-group initializer and previous shortcut algorithm.
These numbers measure shortcut computation only, without rendering or cache hits.

| Catalog / groups | Before median | After median |
| --- | ---: | ---: |
| 500 / 30 | 1.524 ms | 0.255 ms |
| 2,000 / 100 | 12.455 ms | 0.463 ms |
| 10,000 / 300 | 179.449 ms | 1.904 ms |

## Native correctness and timing

Base: `c2ae9cd15cfa74263677006410729eb5d2120933`. Release Swift 6.4,
1280×820 fixture, 500 catalog entries, eight in-memory native sessions and
200 turns each. See [raw measurements and source/binary hashes](measurements.json).
Personal checkout paths in the retained JSON are replaced with `<checkout>`.
The candidate was built from the task's uncommitted source; the manifest's commit
alone identifies the base, so use its source hash to distinguish it from baseline.

- `WorkbenchChecks` passed, including batch-summary equivalence with missing and
  duplicate references, host scopes, archive/offline states, tied ordering and
  selected groups outside the ordinary shortcut limit.
- Native switching: 80 switches passed, including explicit cache invalidation
  checks for pinning, renaming, membership, group selection, catalog replacement
  and empty catalogs/groups. Draft and mounted-session checks passed.
- Switching median / p95: baseline repeat **87.24 / 103.91 ms**, candidate
  **91.41 / 104.31 ms**. The first baseline was 97.30 / 104.78 ms and overlapped a
  core build; it is retained for transparency, not used as speedup evidence.
  This is not enough repeated sampling to establish a whole-window improvement.
- Native `all` passed: session switching, search sheet, session directory,
  scrolling, reading position and bounded transcript hosts. Search-to-layout
  medians were 32.60 ms (sheet) and 52.29 ms (directory), six queries each;
  no search speedup claim without a matching baseline.
- Manual native UI: clicked sidebar session 0002, searched `0003`, pressed Return,
  and verified the selected title/directory and full transcript switched to 0003.
  Screenshot inspection confirmed the existing sidebar/composer appearance.
- Localization coverage and `git diff --check` passed. Live SSH check was skipped
  because `WORKBENCH_LIVE_HOST` was unset.

## Real-app and frame boundary

The ordinary Perch window showed six sessions waiting for restoration and no
online catalog. No real streaming-session or remote-connection performance claim
is made from this run; measurements above use the production views with offline
fixture transport.

Instruments Animation Hitches calibration injected a known 120 ms main-thread
stall. Recording and behavioral checks succeeded, but no app-owned updates could
be joined to displayed frame lifetimes. The verifier correctly returned
`unverified`; zero dropped frames / zero hitches is **not established**. Traces and
logs remain in `.local/sidebar-performance/frame-calibration`.

Next discriminating measurement: connected real sessions, measured during
simultaneous streaming and sidebar/directory interaction, with valid app-owned
frame events and a detected positive control. The remaining roughly 90 ms full
session-switch path needs separate attribution before promising instant switching.

## Reproduce

```sh
PERCH_SIDEBAR_BENCHMARK="$PWD/.local/sidebar-benchmark.json" \
  swift run --build-system native -c release WorkbenchChecks
./scripts/build-native-acceptance.sh
python3 scripts/run-native-acceptance.py --output .local/sidebar-switch --mode switching
python3 scripts/run-native-acceptance.py --output .local/sidebar-all --mode all
python3 scripts/run-native-acceptance.py --output .local/sidebar-frames --capture frames --positive-control
```
