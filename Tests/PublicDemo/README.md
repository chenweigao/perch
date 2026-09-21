# Offline public demo

This standalone window uses the production split view, sidebar shell, session row,
conversation renderer, tool cards, Markdown, model picker, glass and input editor.
All conversations and tool outputs are synthetic. It does not instantiate an agent
connection or load the user's workspace, credentials or conversation history.
The separate bundle identifier also keeps its window preferences isolated.

Build the project first, then build and open the demo:

```sh
./scripts/build.sh
./scripts/build-public-demo.sh
open "build/Perch Demo.app"
```

Select the first pinned task for the overview. Select the regression-test task and
expand the tool card for the detail view. Draft editing and model-menu inspection
are local UI only; sending and remote operations are disabled. Other navigation
shows a demo notice or returns to the first scene.

The build script normally uses this checkout's Release objects. For a local docs
workflow, `WORKBENCH_PREVIEW_BUILD_ROOT` may point to a previously built checkout
with identical `Sources/WorkbenchCore`, `Package.swift` and `Package.resolved`;
verify these match before reusing its build products. Production view sources
always come from the current checkout.

Screenshots in `docs/images` are unaltered captures of this window on macOS 26.
They illustrate the real components with demo data, not live agent acceptance.
Before replacing an image, review its complete contents and metadata. Do not load
real conversations into this fixture or hide private information with overlays.
