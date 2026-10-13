# Disclosure animation

Ported from ccgui's UI/UX spec §2.4. `WorkbenchDisclosureStyle` is the single
disclosure surface (thinking, tool details, runtime context, group pages), so
the rule lives in one place.

Rules, each pointing at `WorkbenchDisclosureContent`:

- Expanding and collapsing run a height transition that pushes siblings; a
  conditional render that flashes content in or out is a bug.
- Content stays mounted while the close animation runs and unmounts when it
  ends. A remembered-expanded row re-appears fully open without replaying the
  animation (view identity resets recreate `mounted = expanded`).
- No opacity fades: content is clipped by height, never ghosted.
- Reduce Motion (system or conversation override) bypasses the transition.

Mechanism: the content measures its natural height via `fixedSize` +
`onGeometryChange`; during a transition the container clips to an animated
height (0 → natural on open, natural → 0 on close), then returns to natural
flow so streaming content keeps resizing without animating every token.

Validation: release build and WorkbenchChecks passed; PerformancePreview
assistant scenario against the parent branch shows no regression (see
docs/STREAM-REVEAL.md for the fixture usage). The benchmark never toggles
disclosures, so it covers only the added container cost, not the animation.
