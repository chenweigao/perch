# Public showcase assets

The current PNGs are **rendered UI illustrations**, not native screenshots.
They follow the current Perch workspace layout: compact title bar, adjustable
sidebar, shared reading/composer width and integrated task inspector. All project
names, conversations and outputs are synthetic. Icons, glass and spacing are
illustrative rather than pixel-exact AppKit rendering.

| File in `docs/images` | Render scene |
| --- | --- |
| `perch-overview.png` | `overview`, light workspace |
| `perch-overview-dark.png` | `dark`, dark workspace |
| `perch-progress.png` | `progress`, ongoing task |
| `perch-tool-details.png` | `details`, integrated task output |
| `perch-new-session.png` | `start`, new task |

Each PNG is an unaltered browser capture of `index.html?scene=<scene>` in a
1280 × 720 viewport. The footer identifies it as a rendered UI illustration with
demo content. No agent was run, and no private session or command output was used.
No external fonts or services are loaded.

## Reproducing

Serve the repository locally and open `docs/showcase/index.html?scene=overview`.
Select the other scenes via the query parameter, capture the complete page and
inspect the export, including the disclosure footer. Check both README variants
before publishing.

The older JPEG captures and promotional compositions remain for historical links.
The separate [PublicDemo](../../Tests/PublicDemo/README.md) fixture is retained;
it is not the source of these PNG renders. These illustrations do not substitute
for running-app visual or functional acceptance.
