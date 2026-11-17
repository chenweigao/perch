import Foundation
let ws = CharacterSet.whitespacesAndNewlines
let probe: [UInt32] = [0x09,0x0A,0x0B,0x0C,0x0D,0x20,0x85,0xA0,0x1680,
  0x2000,0x2001,0x2002,0x2003,0x2004,0x2005,0x2006,0x2007,0x2008,0x2009,0x200A,
  0x200B,0x200C,0x200D,0x2028,0x2029,0x202F,0x205F,0x2060,0x3000,0xFEFF,0x180E,0x00A0]
for u in probe {
    let scalar = Unicode.Scalar(u)!
    let f = ws.contains(scalar)
    let s = Character(String(scalar)).isWhitespace
    let mirror = u == 0x20 || (0x09...0x0D).contains(u) ||
        [0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000].contains(u) || (0x2000...0x200A).contains(u)
    if f != mirror || f != s { print(String(format: "DIFF U+%04X foundation=%d mirror=%d stdlib=%d", u, f ? 1:0, mirror ? 1:0, s ? 1:0)) }
}
print("probe done; trim200B=[\("a\u{200B}".trimmingCharacters(in: .whitespacesAndNewlines))] trimFEFF=[\("a\u{FEFF}".trimmingCharacters(in: .whitespacesAndNewlines))]")
