# Click targets and task-group counts — 2026-09-22

The task-group badge now uses the same unarchived membership projection as the
page. Archived and not-yet-synced references are described separately in the
badge's help text; the page keeps the total number of saved associations.
Search only changes the visible rows, not these totals.

Disclosures in the task group, workbench, transcript and activity details now
use a full-width button header. List headers have a 36 pt minimum height and
compact transcript headers 28 pt. Bare edit, reconnect, attachment-remove and
file-panel buttons have 28 pt targets without enlarging their icons.

## Verification

- Release build and strict application signature verification passed.
- WorkbenchChecks and ConnectionChecks passed. Task-group checks cover archived,
  offline, missing and unrelated references, search, restore and unlink counts.
- Localization coverage passed: 266 scoped keys, 317 table entries.
- Native isolated Task Group Preview: clicking the archive header's right-hand
  blank space expanded it; restoring one fixture session changed 1 unarchived /
  4 archived to 2 / 3. Search narrowed the archive disclosure to one matching row
  while preserving the page totals.
- Native isolated Workbench Preview: clicking the blank space in “展开其余”
  revealed the two remaining result rows.
- Native isolated Tool Visibility Preview: clicking blank space in the transcript
  tool header revealed input/progress. The activity-popover disclosure and close
  button also worked via accessibility actions. Coordinate clicks inside that
  popover were inconclusive.
- Tool preview required `TOOL_VISIBILITY_STATE_DIR` in the built fixture's
  `LSEnvironment`; no real workspace or remote connection was loaded.

## Limits

The running old client was inspected read-only: “环境配置” had 6 archived and no
unarchived sessions; “perch” had 1 unarchived and 4 archived. Its old sidebar
badges counted all 6 and 5 associations. Automatic client restart could not be
completed because its automation window/menu references became invalid after
replacing the app bundle. Real sidebar verification after restart remains open.

The standalone ComposerChecks executable was terminated with exit 137 before
producing test output, including when compiled to a fresh path. That check is
not reported as passed. The release build includes the attachment target change.
No live remote integration or performance acceptance was performed.
