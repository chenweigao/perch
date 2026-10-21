# Perch

**A home for your agents.**

Approved identity (2026-10 redesign): a sunset orb perched on a white branch —
Perch, literally. The branch is tangent to the orb. No letterform, no terminal
glyph, no house.

- `Perch.svg`: editable app icon, transparent outer margin.
- `Perch-mark.svg`: monochrome mark (branch + orb in one ink) on transparency.
- `Perch-1024.png`: 1024 px app icon.
- `Perch.icns`: macOS icon with 16, 32, 128, 256 and 512 point sizes at 1× and 2×.
- `Perch.icon/`: Liquid Glass Icon Composer document; one full-canvas SVG per
  layer (`Assets/`), flat solid fills, backplate is the near-black tile.
- `scripts/generate-brand.swift`: canonical geometry shared by SVG, raster
  exports and the `.icon` layers.

Colors: tile `#1B1E26`→`#121419` (vertical), branch `#FAFAF7`,
orb `#FFD98E`→`#FF7A59` (vertical, sun low on the branch). Where a gradient is
unavailable (Icon Composer layer fill), the orb uses the solid `#FF8455`, which
is deeper than the flat mid-tone because the glass pipeline lightens it.
Keep the orb/branch tangency and the orb left of center. The app icon has a
transparent 100 px outer margin in a 1024 px canvas for the macOS Dock. Use the
standalone mark on light backgrounds. Name and tagline are live text, not part
of the icon.

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

The approved concept was explored with the built-in image-generation tool; these
production assets are deterministic geometry, not cropped from the concept board.
The public app name is Perch. The internal executable, bundle identifier, stored
workspace paths and remote service names keep their existing identities so that
branding does not fork or migrate sessions and preferences.
