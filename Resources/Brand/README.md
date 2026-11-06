# Perch

**A home for your agents.**

Approved identity (2026-11-06): the woodcut terrain stamp (concept 10), with
angular mountains, a winding negative-space path and an irregular partial frame.
Preserve the selected raster's silhouette and distressed grain. The app icon
uses warm charcoal on ivory `#FAF6EF`; in-app marks use the current ink color.
Execution phase indicators retain their sun motions.

- `Perch-mark.png`: unchanged approved transparent master (1254 × 1254), created
  with OpenAI image_gen and selected by the project owner.
- `Perch-1024.png`, `Perch.icns`: macOS fallbacks with a transparent outer margin.
- `Perch.icon`: unmasked raster layer for Icon Composer; the system supplies the
  backplate. The layer retains the master colors, without glass or a cast shadow.
- `Sources/AgentWorkbench/Resources/Perch-mark.png`: generated alpha-bounds crop,
  bundled by SwiftPM for the dashboard and menu-bar template.
- `scripts/brand-export.swift`: deterministic packaging of the approved master;
  no tracing, generated redesign or external image libraries.

Regenerate on macOS from the repository root:

```sh
swift scripts/generate-brand.swift
iconutil -c icns build/Perch.iconset -o Resources/Brand/Perch.icns
./scripts/build.sh
```

The generator compiles the exporter into a temporary executable and removes it.
It does not require a full Swift package build. `build.sh` compiles the Icon
Composer document to `Assets.car`. Check default and dark native renderings
when changing the icon. Keep the transparent master unchanged when regenerating.

The public app name is Perch. Internal executable, bundle identifier, workspace
paths and remote service names retain their identities, preserving sessions
and preferences.
