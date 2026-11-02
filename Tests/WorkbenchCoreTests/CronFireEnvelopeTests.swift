import Foundation
import WorkbenchCore

func checkCronFireEnvelope() throws {
    let sample = """
        <cron-fire jobId="01M6DHPR" cron="26 15 2 11 *" recurring="false" coalescedCount="2" stale="false">
        <prompt>
        检查 chenweigao/perch PR #246 的 CI 终态
        </prompt>
        </cron-fire>
        """
    let envelope = CronFireEnvelope.parse(sample)
    expectEqual(envelope?.cron, Optional("26 15 2 11 *"))
    expectEqual(envelope?.recurring, Optional(false))
    expectEqual(envelope?.coalescedCount, Optional(2))
    expectEqual(envelope?.stale, Optional(false))
    expectEqual(envelope?.prompt, Optional("检查 chenweigao/perch PR #246 的 CI 终态"))

    // A missing prompt block still parses; the tags alone mark the machinery.
    let bare = CronFireEnvelope.parse("<cron-fire jobId=\"x\" cron=\"0 9 * * *\" recurring=\"true\"></cron-fire>")
    expectEqual(bare?.prompt, Optional(""))
    expectEqual(bare?.recurring, Optional(true))

    // Whole-text only: prose around an envelope, other harness markers and
    // ordinary prompts never parse.
    expectEqual(CronFireEnvelope.parse("顺手看看 <cron-fire jobId=\"x\"></cron-fire>") == nil, true)
    expectEqual(CronFireEnvelope.parse("<system-reminder>x</system-reminder>") == nil, true)
    expectEqual(CronFireEnvelope.parse("今天天气怎么样") == nil, true)

    func message(_ text: String, id: String = "1") throws -> KimiMessage {
        try KimiWire.decoder().decode(KimiMessage.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "role": "user", "created_at": "1",
            "content": [["type": "text", "text": text]]]))
    }
    // The wake-up stays a turn anchor while exposing the parsed envelope.
    let fired = try message(sample)
    expectTrue(fired.isUserPrompt)
    expectEqual(fired.cronFire, envelope)
    expectTrue(try message("普通问题").cronFire == nil)

    // Naming and turn excerpts read the inner prompt, never the raw envelope.
    expectEqual(SessionNaming.excerpt(from: [fired]), "检查 chenweigao/perch PR #246 的 CI 终态")
    // An envelope without a prompt holds no title candidate; the next real prompt wins.
    let bareFired = try message("<cron-fire jobId=\"x\"></cron-fire>", id: "2")
    expectEqual(SessionNaming.excerpt(from: [bareFired, try message("真正的标题", id: "3")]), Optional("真正的标题"))
    print("PASS: cron-fire envelope parsing, turn anchoring, naming excerpt")
}
