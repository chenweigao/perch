import Foundation
// Round-19 v2 probe: Character segmentation and OLD-GUARD admission for the
// fused-dollar corners, disambiguating every overload the guard could bind to
// (semantics probe; interpreter mode is fine per INDEX).
func dump(_ label: String, _ s: String) {
    let chars = Array(s).map { Array($0.utf8) }
    var bare = false
    for c in s { if c == "$" { bare = true } }
    print("\(label) CHARS=\(chars)")
    print("\(label) HAS_BARE_CHAR=\(bare)")
    print("\(label) HAS_BYTE=\(s.utf8.contains(36))")
    print("\(label) CONTAINS_CHARACTER_OVERLOAD=\(s.contains("$" as Character))")
    print("\(label) CONTAINS_STRING_OVERLOAD=\(s.contains("$" as String))")
    print("\(label) RANGE_OF_FOUNDATION=\(s.range(of: "$") != nil)")
}
dump("ALLFUSED_PREPEND", "\u{0600}$x\u{0600}$")
dump("ALLFUSED_MARK", "$\u{0308}x$\u{0301}")
dump("OPENER_FUSED_BARE_CLOSER", "\u{0600}$x$")
dump("MARK_OPENER_BARE_CLOSER", "$\u{0308}x$")
