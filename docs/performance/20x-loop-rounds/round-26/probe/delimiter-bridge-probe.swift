// Round-26 design probe: operational canonical-equivalence sweep (round-22
// mechanism) — enumerate every Unicode scalar canonically equal (String ==,
// i.e. the same equivalence relation range(of:) relies on) to the three
// separator atoms used by narrativeText: U+FF1A "：", U+003A ":", U+0020 " ".
// A byte-level first-occurrence search is complete iff no NON-IDENTICAL
// scalar bridges to any atom. Semantics-only: Linux compiled, macOS interpreter.
import Foundation

let atoms: [(String, String)] = [("：", "U+FF1A fullwidth colon"), (":", "U+003A colon"), (" ", "U+0020 space")]
var probe: UInt32 = 0
var bridges: [(String, UInt32)] = []
var checked: UInt32 = 0
while probe < 0x110000 {
    if probe >= 0xD800 && probe <= 0xDFFF { probe = 0xE000; continue }
    if let scalar = Unicode.Scalar(probe) {
        checked += 1
        let s = String(scalar)
        for (atom, _) in atoms where s == atom {
            // identical bytes? (the atom itself)
            if Array(s.utf8) != Array(atom.utf8) { bridges.append((atom, probe)) }
        }
    }
    probe += 1
}
print("scalars-checked:", checked)
print("canonical-bridges-to-separator-atoms:", bridges.count)
for (atom, v) in bridges { print(String(format: "  BRIDGE atom=%@ scalar=U+%04X", atom, v)) }
// Also: two-scalar sequences cannot canonically equal ": " unless one scalar
// alone bridges ":" or " " (canonical decomposition acts per scalar; a
// combining mark cannot cancel into a space) — the per-scalar sweep plus that
// argument is the completeness basis (same reasoning as round-22's multi-scalar
// ideograph composition argument).
print("RESULT:", bridges.isEmpty ? "PASS — byte search for the three atoms is canonically complete" : "FAIL — bridges exist, design must route them")
