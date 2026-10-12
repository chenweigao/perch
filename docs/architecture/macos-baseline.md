# macOS support baseline

Perch supports macOS 26 and newer, including macOS 27. Build with the macOS 26 SDK
or newer. Keep the app manifest, bundle minimum OS and standalone fixture targets
at 26.0; building on a newer OS must not silently raise the fixture minimum.
APIs introduced after macOS 26 still require availability handling while 26 is supported.

This replaces the former macOS 14 minimum. The macOS 14 scroll-following listeners
are removed; all supported systems use content-size changes to schedule following.
The old material fallback is removed, while Reduce Transparency retains its opaque
accessible surface. Current native Liquid Glass behavior is preserved.

The support change is not a measured scrolling speedup. The old listeners computed
observation values (including streaming text and filtered queues) even when their
availability-guarded actions did nothing on newer systems. Removing them eliminates
that unnecessary work and dependency tracking, but the total performance effect has
not been quantified.

The transcript currently explicitly selects TextKit 1 for short selectable text
views. This is a renderer choice, not a requirement imposed by the old minimum OS;
raising the deployment target does not automatically adopt TextKit 2 or eliminate
repeated row layout. Any renderer migration needs its own selection, Unicode,
layout, memory and scrolling comparison.

Validation is recorded in `../validation/2026-10-12-macos26.json`. Local execution
uses macOS 27; a macOS 26 runtime has not been exercised in this workspace.
