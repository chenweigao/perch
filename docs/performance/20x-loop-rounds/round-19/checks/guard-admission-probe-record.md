# Round-19 v2 probe record: old-guard admission for fused-dollar corners

Independent-review findings F2/F3 (round 19) require (a) describing the
existing structural cases correctly and (b) characterizing the old guard as
what the product actually bound to. Probes run 2026-11-15 on the same
toolchains as the A/B (interpreter mode — semantics only, per INDEX this is
invalid for timing, valid for behavior):

- Linux: Alibaba Cloud Linux 3 x86_64, Swift 6.3.3 (`linux-probe.txt`)
- macOS: Mac mini arm64, Apple Swift (`macos-probe.txt`)

Probe source: `guard-probe.swift` — for each input it records Character
segmentation (UTF-8 bytes per Character), bare-"$"-Character presence, byte
presence, and BOTH `contains` overloads disambiguated (`"$" as Character` =
element-wise; `"$" as String` = StringProtocol generic) plus Foundation
`range(of:)`.

| input | Characters (UTF-8) | bare "$" | Mac: Char/String/range | Linux: Char/String/range |
| --- | --- | --- | --- | --- |
| `"\u{0600}$x\u{0600}$"` (all-fused Prepend) | `[D8 80 24][78][D8 80 24]` | no | false / false / false | false / **true** / **true** |
| `"$\u{0308}x$\u{0301}"` (all-fused mark) | `[24 CC 88][78][24 CC 81]` | no | false / false / false | false / false / false |
| `"\u{0600}$x$"` (fused opener, bare closer) | `[D8 80 24][78][24]` | **yes** (trailing) | true / true / true | true / true / true |
| `"$\u{0308}x$"` (mark opener, bare closer) | `[24 CC 88][78][24]` | **yes** (trailing) | true / true / true | true / true / true |

Findings:

1. **The product's old guard bound to the StringProtocol generic, not the
   Character element test**: the Mac cold find-bar trace shows
   `StringProtocol.contains<A>(_:)` → `StringProtocol.range<A>(of:…)` under
   the splitInline closure, and the reviewer's disassembly of the Linux
   baseline shows the same Foundation `range` call (review F3). So the
   operative old-guard admission is the String-overload column above.
2. **Old-guard admission of the all-fused Prepend form is platform-divergent**
   (Linux String overload TRUE, macOS FALSE) — exactly the round-17 finding
   that corelibs substring search lacks GB9b while Character iteration has
   it. The mark-fused form is rejected on both platforms (corelibs search
   handles GB9 Extend). The first Linux probe run (`s.contains("$")`
   unadorned) printed false for the Prepend form — the interpreter bound the
   Character overload there, which is why the explicit-overload probe is the
   archived evidence.
3. **Equivalence invariant holds regardless**: in every divergent cell, the
   admitted-or-rejected run has no bare "$" Character, so `split()`'s walk
   never matches and its terminal flush returns one run with identical text
   and flags — old and new guards produce identical parse output per
   platform. No platform fallback is needed. The new structural cases in
   `checkSplitInlineByteGuard` pin this via direct `splitInline` calls
   (one run, byte-identical text, flags preserved, no math/link/code).
4. The pre-existing structural cases `"\u{0600}$x$"` / `"$\u{0308}x$"` keep a
   **bare trailing closer** (row 3/4: bare "$" = yes) — every guard flavor
   admits them and split() walks into the unmatched closer (review F2: they
   demonstrate the unmatched-closer no-op, NOT the extra-admission path; the
   all-fused rows do).
