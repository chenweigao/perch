# Reply typography

Reference: locally installed Codex 26.915.31945, desktop default Markdown styles.
The installed app's static style resources were inspected read-only; no application
code, fonts, or assets are included in Perch. User font overrides and browser
styles can differ from these desktop defaults.

The native implementation uses:

- System body font at 14 pt, minimum line height 1.625 × font size.
- Semibold heading hierarchy around 21 / 17.5 / 16 pt.
- Tight list items, with paragraph and section spacing doing the grouping.
- Normal text contrast in quotes, identified by indentation and a subtle rule.
- Plain document tables with horizontal separators, without a surrounding card.
- Existing selectable code, link handling, and 760 pt reading column.

Only presentation metrics change. Markdown parsing, cached TextKit measurement,
virtualized history rows, streaming, and thought/tool folding remain unchanged.
The isolated preview uses production Markdown rendering and synthetic content;
it does not load saved sessions or connect to providers.

Build the app with scripts/build.sh, then build the preview with
scripts/build-reply-typography-preview.sh. The preview covers Chinese/English
paragraphs, headings, nested lists, links, inline code, code blocks, quotes,
tables, and the final paragraph at narrower window widths.

Validation (2026-09-21): release build and WorkbenchChecks passed; live SSH
checks were skipped. The isolated preview was checked at approximately 880 and
620 pt window widths. Chinese/English wrapping, list baselines, table cells,
code blocks and the last paragraph remained visible without overlap or clipping.
An observed numbered-list baseline mismatch was corrected using TextKit's
minimum-line-height leading, without adding a layout manager per paragraph.
No new performance benchmark or production-provider acceptance is claimed.
