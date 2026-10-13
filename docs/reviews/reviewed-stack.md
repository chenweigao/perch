# Reviewed feature delivery

All PRs remain unmerged. The original feature branches remain available as the review baseline. Suggested review order: composer → update check → edit statistics → question/disclosure flow → stream reveal → Git writes → reading-first body.

| Finding | Resolution | PR |
| --- | --- | --- |
| R1 wildcard filenames stage unrelated files | Literal pathspecs in add/reset, real filename tests | #128 |
| R2 free text disappears after first character | Explicit question completion and edit-answer control; native typing and Chinese composition checks | #126 |
| R3 live reveal never reached | Current reply remains visible instead of being replaced by the activity summary | #127 |
| R4 repeated frame callbacks / idle spin | Consume one-shot callbacks before invocation; verify production driver arms and returns idle | #127 |
| R5 stale collapse completion hides reopened content | Revision checks and reduced-motion handling; rapid reopen native test | #126 |
| R6 stale branch/history after repository switch | Clear and reread metadata for the selected repository | #128 |
| R7 navigation cancels writes or leaves busy state stuck | Write-owned transport and repository-scoped completion, including local path aliases | #128 |
| R8 detached HEAD displays first branch as current | Preserve the empty current-branch field | #128 |
| R9 cross-session/stale edit statistics | Remove tool-ID global memo; derive from each snapshot | #125 |
| R10 Codex changes array ignored | Parse real bridge `changes` path/diff entries | #125 |
| R11 missing localized strings | Complete update/stats strings and newly added controls in both language tables | #124 / #125 / #126 |

#123 independently preserves the accepted composer feature with actual paste and queue regression checks. A2 plain-code caching is excluded: see `ccgui-followup.md`. The update PR checks stable versions and explains manual updating; it does not claim an automatic signed installer exists. C10 already exists and needs no feature patch.

## Evidence boundaries

Each feature has release build and targeted core/native validation. Git writes additionally passed a real SSH round trip in an isolated temporary development-host repository. The combined source is reviewed separately in `codex/reviewed-integration`; common translation additions and test entry points are explicitly retained when composing branches. CI is checked at each current PR head. Synthetic/native tests do not certify live provider sessions or frame rates.
