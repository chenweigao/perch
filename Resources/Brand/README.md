# Perch

**A home for your agents.**

Approved identity (2026-11 line redesign): a sun ring floating over a branch,
both drawn as lines — Perch, literally. One gap separates the ring from the
branch; the sun sits left of centre. No letterform, no terminal glyph, no house.
It replaces the 2026-10 mark (a gradient orb tangent to a thick white branch).
The app icon draws both lines in white on the brand coral (2026-11-02, replacing
a graphite tile).

- `Perch.svg`: editable app icon, transparent outer margin.
- `Perch-mark.svg`: monochrome mark (branch + ring in one ink) on transparency.
- `Perch-1024.png`: 1024 px app icon.
- `Perch.icns`: macOS icon with 16, 32, 128, 256 and 512 point sizes at 1× and 2×.
- `Perch.icon/`: Liquid Glass Icon Composer document; one full-canvas SVG per
  layer (`Assets/sun.svg`, `Assets/branch.svg`), flat solid fills, backplate is
  the coral tile.
- `scripts/generate-brand.swift`: canonical icon geometry shared by SVG, raster
  exports and the `.icon` layers.

Colors: the brand coral and white, no gradients. Tile `#FF7A59`, branch and
ring `#FFFFFF`. In the app the brand coral is `WorkbenchTheme.Brand.sun`, the
home mark's ring. Icon canvas 1024, line width 64: branch (282, 700)→(742, 700)
with round caps, ring centre (440, 470), radius 140.

In the app the mark is drawn from `PerchLineMark`
(`Sources/AgentWorkbench/PerchBusyIndicator.swift`) on the 24-unit glyph grid
the agent marks use (line width 1.75). The status bar fits it to its 16 pt slot,
runs a chasing arc in the body ink while a turn runs and rests in the quiet ink;
the home mark (`PerchMark`) draws the branch in `ink` and the ring in the brand
hue. Keep the ring/branch gap: at 16 pt touching strokes merge into an Ω.

Regenerate from the repository root on macOS:

```sh
swift scripts/generate-brand.swift
iconutil -c icns build/Perch.iconset -o Resources/Brand/Perch.icns
./scripts/build.sh
```

`build.sh` compiles `Perch.icon` with actool into `Contents/Resources/Assets.car`
and sets `CFBundleIconName`; the icns remains the flattened fallback. To retune
the glass (shadow, translucency, per-appearance fills), open `Perch.icon` in
Icon Composer, then mirror the changes back into `generate-brand.swift` so the
document stays reproducible.

The public app name is Perch. The internal executable, bundle identifier, stored
workspace paths and remote service names keep their existing identities so that
branding does not fork or migrate sessions and preferences.
