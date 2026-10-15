import Foundation
import WorkbenchCore

func checkAutoCompact() {
    let on = AutoCompactSettings(enabled: true, threshold: 80)
    // Gates: disabled, unknown usage, streaming, compacting all refuse.
    precondition(!AutoCompact.shouldCompact(settings: AutoCompactSettings(), usagePercent: 99, streaming: false, compacting: false, attemptedAtPercent: nil))
    precondition(!AutoCompact.shouldCompact(settings: on, usagePercent: nil, streaming: false, compacting: false, attemptedAtPercent: nil))
    precondition(!AutoCompact.shouldCompact(settings: on, usagePercent: 90, streaming: true, compacting: false, attemptedAtPercent: nil))
    precondition(!AutoCompact.shouldCompact(settings: on, usagePercent: 90, streaming: false, compacting: true, attemptedAtPercent: nil))
    // Threshold edge: 79 stays, 80 fires.
    precondition(!AutoCompact.shouldCompact(settings: on, usagePercent: 79, streaming: false, compacting: false, attemptedAtPercent: nil))
    precondition(AutoCompact.shouldCompact(settings: on, usagePercent: 80, streaming: false, compacting: false, attemptedAtPercent: nil))
    // Anti-spin: same level as the last attempt does not refire; growth past it does.
    precondition(!AutoCompact.shouldCompact(settings: on, usagePercent: 85, streaming: false, compacting: false, attemptedAtPercent: 85))
    precondition(AutoCompact.shouldCompact(settings: on, usagePercent: 86, streaming: false, compacting: false, attemptedAtPercent: 85))
    // Threshold clamps into 1...100.
    expectEqual(AutoCompactSettings(enabled: true, threshold: 0).threshold, 1)
    expectEqual(AutoCompactSettings(enabled: true, threshold: 250).threshold, 100)

    // Resume: only a clean threshold compaction continues the task.
    precondition(AutoCompact.shouldResume(thresholdTriggered: true, failed: false, interrupted: false, queuedCount: 0, parked: false))
    precondition(!AutoCompact.shouldResume(thresholdTriggered: false, failed: false, interrupted: false, queuedCount: 0, parked: false))
    precondition(!AutoCompact.shouldResume(thresholdTriggered: true, failed: true, interrupted: false, queuedCount: 0, parked: false))
    precondition(!AutoCompact.shouldResume(thresholdTriggered: true, failed: false, interrupted: true, queuedCount: 0, parked: false))
    precondition(!AutoCompact.shouldResume(thresholdTriggered: true, failed: false, interrupted: false, queuedCount: 2, parked: false))
    precondition(!AutoCompact.shouldResume(thresholdTriggered: true, failed: false, interrupted: false, queuedCount: 0, parked: true))
    print("PASS: auto-compact decisions — gates, threshold edge, anti-spin, resume guards")
}
