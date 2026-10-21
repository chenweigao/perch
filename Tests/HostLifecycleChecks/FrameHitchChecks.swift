import AppKit
import WorkbenchCore

/// The production monitor, its display link and the Settings calibration stall.
/// A runner whose display link delivers nothing prints SKIP; the recorder's
/// logic is covered by WorkbenchChecks.
@MainActor func checkFrameHitchDiagnostics() async throws {
    let diagnostics = PerfDiagnostics.shared
    diagnostics.setEnabled(false)
    // The check runs as an inactive background agent; the app's shared monitor
    // also requires the app to be active.
    let monitor = FrameHitchMonitor(requiresActiveApp: false)
    monitor.install()
    defer {
        monitor.uninstall()
        diagnostics.setEnabled(false)
    }

    // Off: no display link, probes are one Bool read and never build details.
    precondition(!monitor.isRunning, "Diagnostics off must not run a display link")
    precondition(PerfDiagnostics.begin() == 0, "A disabled probe must not read the clock")
    var built = false
    PerfDiagnostics.end("disabled_probe", PerfDiagnostics.begin(), detail: { () -> String in built = true; return "detail" }())
    precondition(!built, "A disabled probe must not evaluate its detail")

    diagnostics.setEnabled(true)
    try await Task.sleep(for: .milliseconds(20))
    guard !NSScreen.screens.isEmpty else {
        print("SKIP: frame-hitch monitor — no screen for a display link on this runner; recorder logic is covered by WorkbenchChecks")
        return
    }
    precondition(monitor.isRunning, "Diagnostics on must start the display link")
    let before = monitor.deliveredFrames
    for _ in 0..<50 {
        if monitor.deliveredFrames - before >= 10 { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    let delivered = monitor.deliveredFrames - before
    guard delivered > 0 else {
        print("SKIP: frame-hitch monitor — the display link delivered no frames in 1 s (headless runner); recorder logic is covered by WorkbenchChecks")
        return
    }

    PerfDiagnostics.injectCalibrationStall()
    func calibrated() -> (FrameHitchRecorder.Hitch, FrameHitchRecorder.StageShare)? {
        for hitch in diagnostics.frameReport().worstHitches {
            if let share = hitch.work.first(where: { $0.stage == "calibration_stall" }) { return (hitch, share) }
        }
        return nil
    }
    for _ in 0..<50 {
        if calibrated() != nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    guard let found = calibrated() else {
        fatalError("The 120 ms calibration stall was not recorded as a hitch: \(diagnostics.frameReport())")
    }
    let (hitch, share) = found
    // The late frame's vsync can precede the end of the stall by one interval;
    // at 50 Hz and above the floor is 100 ms.
    let expected = min(100, 120 - hitch.intervalMS - 1)
    precondition(hitch.gapMS >= expected, "Calibration hitch gap \(hitch.gapMS) ms is under \(expected) ms")
    precondition(share.ms >= expected, "Calibration stall attributed \(share.ms) ms, expected at least \(expected) ms")
    precondition(share.details == ["120ms"])
    let report = diagnostics.report()
    precondition(report.contains("\"frames\"") && report.contains("\"worst_hitches\"") && report.contains("calibration_stall")
                 && report.contains("\"source_revision\"") && report.contains("\"bundle_version\"") && report.contains("\"macos\""),
                 "Exported report lacks the frames section or build identity")
    let counters = diagnostics.frameReport().counters
    print("Frame hitch fixture: \(delivered) frames in the first wait, calibration gap \(hitch.gapMS) ms, "
          + "attributed \(share.ms) ms, \(counters.observed) observed, \(counters.hitches) hitches")

    diagnostics.setEnabled(false)
    try await Task.sleep(for: .milliseconds(20))
    precondition(!monitor.isRunning, "Turning diagnostics off must stop the display link")
    precondition(diagnostics.frameReport().worstHitches.isEmpty && diagnostics.frameReport().counters.observed == 0,
                 "Turning diagnostics off must clear the frame recording")
    print("PASS: frame-hitch monitor — off path idle, display link frames, calibration stall caught and attributed, export sections, off clears")
}
