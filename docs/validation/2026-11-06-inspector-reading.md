# Inspector reading continuity — 2026-11-06

## Installed native application

Tested application source: `4070732be614efc745391626c9b06b73cc76c227`
(`v0.6.0-45-g4070732`). Built with `scripts/build.sh`, installed in the user's
Applications directory, and launched from that installed bundle. Its executable
SHA-256 was `e9fa5e3fb2c7a4f0a8618b49110693e722b19fddaae67d67722ab7a7ad1bca37`;
strict deep code-signature verification passed. Other already-running builds were
left untouched; the installed application was selected by its full path.

Real remote Kimi sessions were exercised using the native UI and inspected with
accessibility state and screenshots. Session names, private paths, and transcript
contents are intentionally omitted from this public record.

| Interaction | Observed result |
| --- | --- |
| First inspector reveal | Full-height auxiliary lane; transcript and composer remain aligned; no overlap in the inspected dark-appearance window. |
| Scroll a 36-task overview, close, reopen | Native scrollbar remained at `1.0`, rather than resetting to `0`. |
| Expand finished tasks, switch A → B → A | Expansion remained open; overview scrollbar restored to `0.379291553133515`. B displayed its own two artifacts and four tasks. |
| Open a long remote Markdown artifact, scroll, return, reopen | Reading resumed below the beginning. Existing ambiguous-basename resolution required selecting the same absolute-path candidate again. |
| Lock the source, switch main session | Inspector retained the original source title and document while the main transcript showed the other session. |
| Reconnect the client through environment controls | Offline rows and the recent-content warning appeared, then the connection returned to connected. After resolving the same document candidate, the same visible paragraph boundary and following section were restored. No remote service restart or agent message was issued. |

The document renderer estimates its total extent lazily, so its normalized
scrollbar fraction changes as layout progresses. The live document check establishes
visual reading continuity, not exact normalized-fraction equality or a performance
measurement. Ambiguous file-reference selection itself is not remembered by this
change. Reading metadata lasts for this application run; document content is read
again when reopening.

## Local automated evidence

All completed successfully on the tested source:

- `scripts/build.sh`
- `swift run --build-system native -c release --skip-build WorkbenchChecks`
- `python3 scripts/check-host-lifecycle.py --phase task-context --phase document-reading --phase task-detail --phase file-reader --phase code-reader`
- `python3 scripts/check-preview-sources.py`
- `python3 scripts/check-localization.py`
- `git diff --check`

Native regression checks cover overview remount at a 600-point offset, session /
host / provider isolation, expansion retention, shortened-content clamping, and
inline-file back/reopen with an actual native scroll view. Existing file and code
reader checks also passed. The real-session observations above are separate from
these fixtures. Hosted CI and merge status are recorded by the pull request, not
inferred from local results.
