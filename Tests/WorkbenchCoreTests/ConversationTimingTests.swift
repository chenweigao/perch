import Foundation
import WorkbenchCore

func checkConversationTiming() {
    func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
    var clocks = ConversationTimings()
    clocks.submitted("request-1", at: date(100))
    clocks.observe(sessionID: "one", turnID: "turn-1", requestID: "request-1", running: true, waiting: false, at: date(103))
    precondition(clocks.turns["one"]?.elapsed(at: date(179)) == 79)
    precondition(clocks.turns["one"]?.observedOnly == false)
    clocks.observe(sessionID: "one", running: true, waiting: true, at: date(180))
    clocks.observe(sessionID: "two", turnID: "other", running: true, waiting: false, at: date(190))
    // Returning to a session and binding the same turn must preserve its clock.
    clocks.observe(sessionID: "one", turnID: "turn-1", requestID: "request-1", running: true, waiting: false, at: date(210))
    precondition(clocks.turns["one"]?.elapsed(at: date(220)) == 120)
    precondition(clocks.turns["one"]?.waiting(at: date(220)) == 30)
    clocks.observe(sessionID: "one", running: false, waiting: false, at: date(228))
    clocks.observe(sessionID: "one", running: false, waiting: false, at: date(260))
    precondition(clocks.turns["one"]?.elapsed(at: date(999)) == 128, "Completion freezes the clock")
    precondition(clocks.turns["two"]?.observedOnly == true, "Attaching midway must not invent a request start")
    clocks.observe(sessionID: "two", turnID: "other", running: true, waiting: false, at: date(230))
    precondition(clocks.turns["two"]?.elapsed(at: date(240)) == 50)
    clocks.observe(sessionID: "one", turnID: "turn-2", running: true, waiting: false, at: date(300))
    precondition(clocks.turns["one"]?.elapsed(at: date(310)) == 10)
    precondition(clocks.turns["one"]?.waiting(at: date(310)) == 0)

    // Catalog discovery can precede the snapshot identifying the submitted prompt.
    clocks.submitted("late-prompt", at: date(400))
    clocks.observe(sessionID: "late", running: true, waiting: false, at: date(405))
    clocks.observe(sessionID: "late", turnID: "late-turn", requestID: "late-prompt", running: true, waiting: false, at: date(410))
    precondition(clocks.turns["late"]?.elapsed(at: date(420)) == 20 && clocks.turns["late"]?.observedOnly == false)

    // Codex assigns a runtime turn ID that differs from the client request ID.
    clocks.submitted("client-request", at: date(450))
    clocks.observe(sessionID: "mapped", turnID: "runtime-turn", requestID: "client-request",
                   running: true, waiting: false, at: date(452))
    clocks.finished(sessionID: "mapped", requestID: "client-request", turnID: "runtime-turn", at: date(460))
    precondition(clocks.turns["mapped"]?.elapsed(at: date(999)) == 10,
                 "A mapped runtime turn must freeze from the original submission")

    // A fast native turn may finish before the first busy catalog arrives.
    clocks.submitted("fast", at: date(500))
    clocks.finished(sessionID: "fast-session", requestID: "fast", at: date(501))
    clocks.finished(sessionID: "fast-session", requestID: "fast", at: date(510))
    precondition(clocks.turns["fast-session"]?.elapsed(at: date(999)) == 1)
    clocks.observe(sessionID: "fast-session", turnID: "next", running: true, waiting: false, at: date(520))
    clocks.finished(sessionID: "fast-session", requestID: "fast", at: date(530))
    precondition(clocks.turns["fast-session"]?.turnID == "next" && clocks.turns["fast-session"]?.endedAt == nil)
    clocks.submitted("next-fast", at: date(540))
    clocks.observe(sessionID: "fast-session", turnID: "next-fast", requestID: "next-fast", running: false, waiting: false, at: date(541))
    precondition(clocks.turns["fast-session"]?.elapsed(at: date(999)) == 1, "A completed new turn must replace the old clock")

    clocks.submitted("promoted", at: date(550))
    clocks.finished(sessionID: "fast-session", requestID: "promoted", turnID: "promoted-runtime", at: date(551))
    precondition(clocks.turns["fast-session"]?.turnID == "promoted-runtime"
                 && clocks.turns["fast-session"]?.elapsed(at: date(999)) == 1,
                 "A completion-only new prompt must replace the previous ended turn")
    clocks.finished(sessionID: "fast-session", requestID: "next-fast", at: date(552))
    precondition(clocks.turns["fast-session"]?.turnID == "promoted-runtime",
                 "A delayed old receipt must not rewind a newer clock")

    precondition(ConversationTiming.duration(79, chinese: true) == "1分19秒")
    precondition(ConversationTiming.duration(128, chinese: true) == "2分08秒")
    precondition(ConversationTiming.duration(3661, chinese: false) == "1h 1m 1s")
    print("PASS: request/observed timing, session switching, wait accounting, completion freeze and turn isolation")
}
