# Public showcase assets

The current PNGs in `docs/images` (2026-11-26) are **native view renders** of the
production workspace, not browser illustrations. All project names, conversations
and outputs are synthetic fixture data; no agent ran and no private session was used.

| File in `docs/images` | Source capture |
| --- | --- |
| `perch-overview.png` | `native-light.png` — `check-host-lifecycle.py --phase native-design` |
| `perch-overview-dark.png` | `native-dark.png` — same phase, dark appearance |
| `perch-tool-details.png` | `native-task-overview-light.png` — same phase, inspector overview with draft and attachment |
| `perch-progress.png` | `native-inspector-closed-light.png` — same phase, inspector closed |
| `perch-new-session.png` | `NewTaskView` from `scripts/build-new-task-preview.sh`, captured with `PERCH_PREVIEW_CAPTURE` |

## What is and is not native

The captures are AppKit view caches (`cacheDisplay`). They contain every view the
app draws, including the white / blue-graphite glass underlay, but not what the
window server composites: the Liquid Glass blur, the window shadow and the title-bar
traffic lights. `compose.py` places each capture over a smooth gradient (the blur of
a smooth field is the field itself), masks the window corner, adds a soft shadow and
draws the three traffic lights at the native-design geometry. The footer of every PNG
says so. When screen recording is available to the capture process, the
native-design phase also writes `*-composited-window.png` system captures; prefer
those for the overview pair.

## Reproducing

On a Mac with the repository built (`scripts/build.sh`):

```sh
PERCH_DESIGN_CAPTURES=/tmp/perch-design python3 scripts/check-host-lifecycle.py --phase native-design
scripts/build-new-task-preview.sh
PERCH_PREVIEW_CAPTURE=/tmp/perch-design/new-task-light.png "build/NewTask Preview.app/Contents/MacOS/NewTaskPreview"
```

Then, anywhere with Pillow:

```sh
python3 docs/showcase/compose.py /tmp/perch-design/native-light.png docs/images/perch-overview.png light
python3 docs/showcase/compose.py /tmp/perch-design/native-dark.png docs/images/perch-overview-dark.png dark
python3 docs/showcase/compose.py /tmp/perch-design/native-task-overview-light.png docs/images/perch-tool-details.png light
python3 docs/showcase/compose.py /tmp/perch-design/native-inspector-closed-light.png docs/images/perch-progress.png light
python3 docs/showcase/compose.py /tmp/perch-design/new-task-light.png docs/images/perch-new-session.png light
```

The native-design phase ends with hover checks that need an active app; run from an
SSH session it captures everything above and then fails at that step, which does
not affect the renders.

`index.html` is the browser illustration used until 2026-11-26 and the older JPEG
captures remain for historical links. The separate
[PublicDemo](../../Tests/PublicDemo/README.md) fixture is retained. None of these
substitute for running-app visual or functional acceptance.
