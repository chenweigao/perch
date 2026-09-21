# Perch

**A home for your agents.**

Approved identity: a tall vertical stem plus a green terminal chevron and a white
underscore, suggesting the letter P. No house, bird or Chinese wordmark.

- `Perch.svg`: editable app icon, transparent outer margin.
- `Perch-mark.svg`: monochrome mark on transparency.
- `Perch-1024.png`: 1024 px app icon.
- `Perch.icns`: macOS icon with 16, 32, 128, 256 and 512 point sizes at 1× and 2×.
- `scripts/generate-brand.swift`: canonical geometry shared by SVG and raster exports.

Colors: charcoal `#292D37`, warm white `#FAFAF7`, mint green `#55E58B`.
Keep the glyph proportions and negative space. The app icon has a transparent
100 px outer margin in a 1024 px canvas for the macOS Dock. Use the standalone
mark on light backgrounds. Name and tagline are live text, not part of the icon.

Regenerate from the repository root on macOS:

```sh
swift scripts/generate-brand.swift
iconutil -c icns build/Perch.iconset -o Resources/Brand/Perch.icns
./scripts/build.sh
```

The approved concept was explored with the built-in image-generation tool; these
production assets are deterministic geometry, not cropped from the concept board.
The public app name is Perch. The internal executable, bundle identifier, stored
workspace paths and remote service names keep their existing identities so that
branding does not fork or migrate sessions and preferences.
