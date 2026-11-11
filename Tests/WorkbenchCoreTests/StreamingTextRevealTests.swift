import Foundation
import WorkbenchCore

func checkStreamingTextReveal() {
    let prefix = "已显示的正文。"
    var reveal = StreamingTextReveal(prefix)
    precondition(reveal.text == prefix && !reveal.hasBacklog, "Opening history never replays its text")
    let burst = prefix + String(repeating: "平滑追加中文正文与代码。", count: 80)
    reveal.update(burst, smoothing: true)
    precondition(reveal.text == prefix && reveal.hasBacklog, "A cumulative burst starts at the existing prefix")
    var previous = prefix
    for _ in 0..<30 {
        reveal.advance(elapsed: StreamingTextReveal.frameInterval)
        precondition(reveal.text.hasPrefix(previous) && burst.hasPrefix(reveal.text), "Release stays monotonic and never invents text")
        previous = reveal.text
    }
    precondition(reveal.text == burst && !reveal.hasBacklog, "A large burst catches up within 500 ms")
    reveal.update(burst + "未显示的尾部", smoothing: true)
    reveal.update("修订后的同一条消息", smoothing: true)
    precondition(reveal.text == "修订后的同一条消息" && !reveal.hasBacklog, "Replacements cannot retain stale characters")

    let unicode = "👩🏽‍💻é🇨🇳中文👨‍👩‍👧‍👦"
    var characters = StreamingTextReveal("")
    characters.update(unicode, smoothing: true)
    let boundaries = (0...unicode.count).map { String(unicode.prefix($0)) }
    while characters.hasBacklog {
        characters.advance(elapsed: StreamingTextReveal.frameInterval)
        precondition(boundaries.contains(characters.text), "Every visible prefix ends on a complete grapheme")
    }
    precondition(characters.text == unicode)

    var fractional = StreamingTextReveal("")
    fractional.update(String(repeating: "a", count: 12), smoothing: true)
    for _ in 0..<6 { fractional.advance(elapsed: 1.0 / 120) }
    precondition(fractional.text.count == 3, "Fractional frames preserve the 60 characters/sec base rate")
    fractional.update("终止立即显示的完整正文", smoothing: false)
    precondition(!fractional.hasBacklog && fractional.text == "终止立即显示的完整正文")
    fractional.update(String(repeating: "长", count: StreamingTextReveal.maximumLength + 1), smoothing: true)
    precondition(!fractional.hasBacklog && fractional.text.count == StreamingTextReveal.maximumLength + 1,
                 "Oversized output stays immediate and owns no release queue")

    var continuous = StreamingTextReveal("")
    var latest = ""
    for _ in 0..<60 {
        latest += "继续流式追加"
        continuous.update(latest, smoothing: true)
        continuous.advance(elapsed: StreamingTextReveal.frameInterval)
    }
    continuous.update(latest + "最终结果", smoothing: false)
    precondition(continuous.text == latest + "最终结果" && !continuous.hasBacklog, "Completion flushes the newest target without dropping a delta")
    print("PASS: bounded adaptive text release, Unicode boundaries, replacement and immediate completion")
}
