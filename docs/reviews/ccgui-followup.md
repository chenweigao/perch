# ccgui follow-up review, 2026-10-13

Source inspected: `zhukunpenglinyutong/desktop-cc-gui` at `cc561dbb880f93b3bb312231a71376b8b0510b0e`. Source inspection establishes implementation, not live product acceptance. The README names MIT but this checkout has no LICENSE file; this follow-up reimplements interaction ideas in Perch's native architecture, without copying source/assets.

## Additional ideas worth considering

| Idea and source | Perch comparison | Decision |
| --- | --- | --- |
| [Bounded long user messages](https://github.com/zhukunpenglinyutong/desktop-cc-gui/blob/cc561dbb880f93b3bb312231a71376b8b0510b0e/src/features/chat/components/CollapsibleMessage.tsx): measured expansion, late image resize, Reduce Motion | Native and Markdown user rows now fold based on measured height. | Implemented in reading controls; full copy/search and reading anchors are preserved. |
| [Process disclosure](https://github.com/zhukunpenglinyutong/desktop-cc-gui/blob/cc561dbb880f93b3bb312231a71376b8b0510b0e/src/features/chat/components/ProcessDisclosure.tsx): explicit user override, bounded pages, search opens the matching page | Completed process groups now mount eight timeline rows per page. | Implemented with remembered page anchors and search into later pages, including long output viewports. |
| [Plan decision dock](https://github.com/zhukunpenglinyutong/desktop-cc-gui/blob/cc561dbb880f93b3bb312231a71376b8b0510b0e/src/features/chat/components/PlanReviewDock.tsx): revision-aware decisions, conflict retention, neutral initial focus | Claude ExitPlanMode now carries a versioned review payload from SDK inline text or this query’s plan file. | Implemented approval, feedback, defer/resume and conflict retention. Other providers need a real approval protocol before receiving this UI. |
| [Anchor rail](https://github.com/zhukunpenglinyutong/desktop-cc-gui/blob/cc561dbb880f93b3bb312231a71376b8b0510b0e/src/features/chat/components/MessageAnchorRail.tsx): bounded markers, keyboard previews, edge-aware positioning | Perch already has a turn navigator, preview, bookmarks and current-turn tracking. | Keep existing navigation; no duplicate rail. |
| [Scroll intent](https://github.com/zhukunpenglinyutong/desktop-cc-gui/blob/cc561dbb880f93b3bb312231a71376b8b0510b0e/src/features/chat/components/use-scroll-follow.ts): wheel pauses follow; growth cannot restart it | Perch already observes user scrolling independently from content growth. | Preserve and regression-test. |
| [Highlight caching](https://github.com/zhukunpenglinyutong/desktop-cc-gui/blob/cc561dbb880f93b3bb312231a71376b8b0510b0e/src/features/chat/components/cached-highlight.ts): bounded expensive syntax results, closed fences, component lifetime | The proposed Perch port caches cheap plain attributed strings globally. The computational cost is different. | Exclude A2 from delivery. Decide syntax highlighting separately, with dark/light, unknown languages, copying and real rendering measurements. |

## Cache experiment boundary

Local candidate `fix/reviewed-code-cache` / `19be4df` retains the reproducible native test. On this Mac, one 1,000-construction probe with a 200-line Chinese/code source measured cached 0.01680 s versus plain construction 0.00301 s. Identity, exact attributes, LRU eviction and character bounds passed. This single microbenchmark is not an app/FPS result or a general performance conclusion; it is insufficient evidence to ship the extra global cache. No cache is included in the accepted PR set.

## Reading-first direction

Keep final answers in a stronger, comfortable text column. Give headings a real hierarchy shared by native and fallback renderers. Keep thoughts and successful tools behind clear disclosures; preserve failed/pending/uncertain tools in view. Preserve copy, quote, regenerate, links, code gutters, horizontal code scrolling, search, bookmarks, turn navigation and user-controlled follow mode. Preserve the native glass sidebar and composer.
