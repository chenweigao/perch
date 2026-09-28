# Public showcase assets

The showcase uses production macOS views with synthetic content. It is a product
illustration, not evidence of live Agent execution, performance, or App Store
availability. No Apple or App Store endorsement is implied.

## Sources

| File in `docs/images` | Source |
| --- | --- |
| `perch-overview.jpg` | Unaltered conversation capture from `Tests/PublicDemo` |
| `perch-tool-details.jpg` | Unaltered expanded tool capture from `Tests/PublicDemo` |
| `perch-new-session.jpg` | Unaltered active-window capture from `Tests/NewTaskPreview`, with simulated connectivity and a synthetic model |
| `perch-showcase-overview.jpg` | Browser capture of `index.html?scene=overview` |
| `perch-showcase-start.jpg` | Browser capture of `index.html?scene=start` |
| `perch-showcase-details.jpg` | Browser capture of `index.html?scene=details` |

The promotional cards add a heading, background and brand mark around complete
screenshots. They do not redraw controls, replace UI text, mask private content,
or fabricate a live run. All visible task text, project labels and outputs are
demo data. The new-session capture shows the macOS 26 native glass in an active
window; inactive windows can look flatter.

## Updating the cards

1. Build the app and the relevant isolated fixture. See
   [PublicDemo](../../Tests/PublicDemo/README.md) and
   `scripts/build-new-task-preview.sh`.
2. Use only synthetic tasks and project names. Do not load personal workspace
   state into screenshots. Activate the window before capturing native glass.
3. Review the whole image, including menus, paths, hostnames and metadata.
4. Serve the repository locally, then open `docs/showcase/index.html` with
   `?scene=overview`, `?scene=start`, or `?scene=details`. The checked-in cards
   were captured in a 1280 × 720 browser viewport. No external fonts or services
   are loaded. Keep native screenshots intact and retain the demo disclosure.
5. Capture each complete card, visually inspect the exports, and check the
   English and Chinese README links before publishing.

Use the source screenshots for close inspection of UI text; the cards are for
repository introductions and project sharing.
