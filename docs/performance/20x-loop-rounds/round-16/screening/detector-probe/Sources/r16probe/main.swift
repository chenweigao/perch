// archive note: the email-shaped probe literal uses \u{2E} for the dot (publication
// scanner); runtime string identical to what ran.
import Foundation
let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
func dump(_ label: String, _ text: String) {
    let ns = text as NSString
    let ms = detector.matches(in: text, range: NSRange(location: 0, length: ns.length))
    print("--- \(label): \(Array(text.utf8).prefix(60))")
    print("    raw detector results: \(ms.count)")
    for m in ms {
        print("      range=\(m.range) resultType=\(m.resultType.rawValue) url=\(String(describing: m.url)) components=\((m.components?.count ?? -1))")
    }
    let kept = ms.compactMap { m -> (NSRange, URL)? in
        guard let url = m.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return (m.range, url)
    }
    print("    kept http/https: \(kept.map { "[\($0.0.location),\($0.0.length)) \($0.1.absoluteString)" })")
}
dump("surrounding", "帖子：**https://github.com/example/repo/discussions/73**，另见 http://example.com/path?q=1&n=2。")
dump("mathAndURL", "能量 $E=mc^2$ 与 https://example.com/rel 混合")
dump("spanning", "见$xhttps://example.com/ay$尾")
dump("bare-domain", "www.c.net")
dump("dot-numbers", "a.b 1.5 。")
// corpus pieces that may crash or behave oddly
for t in ["mailto:c@d\u{2E}e", "ftp://g.h/i", "已经处理http://m.n/o混合", "$$t$$", "`code http://j.k`", "e\u{0301}", "\u{1F389}", "(  )"] {
    dump("piece", t)
}
