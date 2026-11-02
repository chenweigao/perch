# Perch

**A home for your agents.**

Approved identity (2026-11-02): the D1 perched bird, in deep coral `#E36D55`
and white. A centered branch supports a near-symmetric body; the short right
beak and single wing supply the asymmetry. In-app brand moments use one ink,
following the appearance. Execution phase indicators retain their sun motions.

- `Perch.svg`: app icon with a transparent outer margin.
- `Perch-mark.svg`: monochrome bird on transparency.
- `Perch-1024.png`, `Perch.icns`: flattened macOS fallbacks.
- `Perch.icon`: unmasked Icon Composer bird layer; system backplate and lighting.
- `Sources/AgentWorkbench/PerchBirdGeometry.swift`: the actual CoreGraphics paths,
  used by the app and raster generator. On a 100-unit grid the outer stroke is
  5.4, wing 5.2, and belly-to-branch clear gap 9.6. At 16/24pt the strokes are
  adjusted and the foreground enlarged by 8%/4%; 32pt and above use the master.
- `scripts/brand-export.swift`: matching editable SVGs and Icon Composer package.

Regenerate on macOS from the repository root:

```sh
swift scripts/generate-brand.swift
iconutil -c icns build/Perch.iconset -o Resources/Brand/Perch.icns
./scripts/build.sh
```

The generator compiles the app's bird geometry and exporter into a temporary
executable, then removes it. It does not require a full Swift package build.
`build.sh` compiles the Icon Composer document to `Assets.car`. Check default
and dark native renderings when changing the icon. System appearances can
change the background and foreground colors while retaining the bird.

The public app name is Perch. Internal executable, bundle identifier, workspace
paths and remote service names retain their identities, preserving sessions
and preferences.
