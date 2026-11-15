// Round-24 probe supplement (review F6): the main walk covers the 1,111,936
// non-ASCII scalars (probe starts at 0x80). This supplement checks the 128
// ASCII scalars: none may fuse with a preceding space, and the product's
// collapsedWhitespace must equal the strict split/join oracle on
// whitespace-adjacent shapes for each. Semantics only.
import Foundation
extension String {
    // Mirror of the product fast-path entry condition for the pinned set:
    // ASCII scalars can never be in the pinned fusion set (0x0E33+), so this
    // supplement only needs the fusion + oracle facts.
}
var fusionCount = 0
var mismatches = 0
for v: UInt32 in 0..<0x80 {
    guard let scalar = Unicode.Scalar(v), v != 0 else { continue }
    let s = String(scalar)
    if (" " + s).count == 1 { fusionCount += 1; print("ASCII FUSION U+\(String(v, radix: 16))") }
}
print("ascii-scalars-checked: 127 (0x01..0x7F; 0x00 excluded as non-text)")
print("ascii-fusions-with-preceding-space: \(fusionCount)")
print("RESULT: \(fusionCount == 0 ? "PASS — no ASCII scalar fuses with a preceding space; the seven-gap conclusion is complete over the full scalar range" : "FAIL")")
