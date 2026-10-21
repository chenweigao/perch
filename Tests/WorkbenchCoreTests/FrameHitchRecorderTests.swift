import Foundation
import WorkbenchCore

/// Frame-hitch accounting with synthetic timestamps: no display, no clock.
func checkFrameHitchRecorder() throws {
    func share(_ hitch: FrameHitchRecorder.Hitch?, _ stage: String) -> FrameHitchRecorder.StageShare? {
        hitch?.work.first { $0.stage == stage }
    }
    /// observed, scrolling, hitches, scrolling hitches, missed, scrolling missed.
    func counts(_ counters: FrameHitchRecorder.Counters) -> [Int] {
        [counters.observed, counters.scrolling, counters.hitches, counters.scrollingHitches,
         counters.missedFrames, counters.scrollingMissedFrames]
    }

    // Steady frames at 120 Hz: the first frame only sets the baseline.
    do {
        let interval = 1.0 / 120
        var recorder = FrameHitchRecorder()
        for index in 0...120 {
            expectTrue(recorder.frame(timestamp: 10 + Double(index) * interval, duration: interval, scrolling: false) == nil)
        }
        let report = recorder.report()
        expectEqual(counts(report.counters), [120, 0, 0, 0, 0, 0])
        expectEqual(report.gapHistogram.byInterval.map(\.count), [120, 0, 0, 0, 0])
        expectEqual(report.gapHistogram.byMS.first?.count, 120)
        expectEqual(report.displayIntervalMS.map { [$0.last, $0.min, $0.max] }, [8.33, 8.33, 8.33])
        expectEqual(report.worstHitches, [])
        expectEqual(report.recordingMS, 1_000)
    }

    // One long gap at 120 Hz with overlapping work: clipped at the window start,
    // intervals outside the window ignored, the rest unattributed.
    do {
        let interval = 1.0 / 120
        var recorder = FrameHitchRecorder(origin: 0.5)
        recorder.frame(timestamp: 1, duration: interval, scrolling: false)
        recorder.work(stage: "before", start: 0.99, end: 0.999)
        recorder.work(stage: "row_measure", start: 0.995, end: 1.06, detail: "renderer=hosted presentation=message")
        recorder.work(stage: "attributed_text", start: 1.07, end: 1.1, detail: "paragraphs=3")
        recorder.work(stage: "after", start: 1.13, end: 1.14)
        let hitch = recorder.frame(timestamp: 1.125, duration: interval, scrolling: true, phase: "changed")
        expectEqual(hitch?.gapMS, 125)
        expectEqual(hitch?.missedFrames, 14)
        expectEqual(hitch?.startMS, 500)
        expectEqual(hitch?.scrolling, true)
        expectEqual(hitch?.phase, "changed")
        expectEqual(hitch?.work.map(\.stage), ["row_measure", "attributed_text"])
        expectEqual(share(hitch, "row_measure")?.ms, 60)
        expectEqual(share(hitch, "row_measure")?.details, ["renderer=hosted presentation=message"])
        expectEqual(share(hitch, "attributed_text")?.ms, 30)
        expectEqual(hitch?.attributedMS, 90)
        expectEqual(hitch?.unattributedMS, 35)
        expectEqual(hitch?.journalTruncated, false)
        let report = recorder.report()
        expectEqual(counts(report.counters), [1, 1, 1, 1, 14, 14])
        expectEqual(report.blame.map(\.stage), ["row_measure", "attributed_text"])
        expectEqual(report.unattributedMS, 35)
    }

    // Nested and partial intervals at 60 Hz: self time subtracts nested probes,
    // so the stage shares and the unattributed remainder add up to the gap.
    do {
        let interval = 1.0 / 60
        var recorder = FrameHitchRecorder(origin: 0)
        recorder.frame(timestamp: 2, duration: interval, scrolling: false)
        recorder.work(stage: "attributed_text", start: 2.02, end: 2.035, detail: "paragraphs=1")
        recorder.work(stage: "row_setup", start: 2.01, end: 2.05, detail: "renderer=native_assistant")
        recorder.work(stage: "row_measure", start: 2.06, end: 2.07)
        recorder.work(stage: "transcript_refresh", start: 1.95, end: 2.085, detail: "source=clip_bounds rows=6 entered=2 exited=1 created=1")
        recorder.work(stage: "text_measure", start: 2.095, end: 2.2)
        let hitch = recorder.frame(timestamp: 2.1, duration: interval, scrolling: false)
        expectEqual(hitch?.missedFrames, 5)
        expectEqual(hitch?.scrolling, false)
        expectEqual(hitch?.work.map(\.stage), ["transcript_refresh", "row_setup", "attributed_text", "row_measure", "text_measure"])
        expectEqual(hitch?.work.map(\.ms), [35, 25, 15, 10, 5])
        expectEqual(hitch?.work.map(\.inclusiveMS), [85, 40, 15, 10, 5])
        expectEqual(hitch?.work.map(\.count), [1, 1, 1, 1, 1])
        expectEqual(hitch?.attributedMS, 90)
        expectEqual(hitch?.unattributedMS, 10)
        expectEqual(hitch?.otherStagesMS, 0)
    }

    // Equal intervals: the one recorded later encloses the earlier one.
    do {
        var recorder = FrameHitchRecorder(origin: 0)
        recorder.frame(timestamp: 3, duration: 0.01, scrolling: false)
        recorder.work(stage: "inner", start: 3, end: 3.05)
        recorder.work(stage: "outer", start: 3, end: 3.05)
        let hitch = recorder.frame(timestamp: 3.1, duration: 0.01, scrolling: false)
        expectEqual(share(hitch, "inner")?.ms, 50)
        expectEqual(share(hitch, "outer")?.ms, 0)
        expectEqual(share(hitch, "outer")?.inclusiveMS, 50)
        expectEqual(hitch?.unattributedMS, 50)
    }

    // Histogram at an unusual 100 Hz: one gap per interval bucket, and the
    // millisecond buckets read the same gaps in absolute time.
    do {
        var recorder = FrameHitchRecorder(origin: 0)
        for timestamp in [0, 0.01, 0.03, 0.07, 0.15, 0.35] {
            recorder.frame(timestamp: timestamp, duration: 0.01, scrolling: false)
        }
        let report = recorder.report()
        expectEqual(report.gapHistogram.byInterval.map(\.count), [1, 1, 1, 1, 1])
        expectEqual(report.gapHistogram.byInterval.map(\.lower), [0, 1.5, 3, 6, 12])
        expectEqual(report.gapHistogram.byInterval.map(\.upper), [1.5, 3, 6, 12, nil])
        expectEqual(report.gapHistogram.byMS.map(\.count), [1, 1, 1, 1, 1, 0, 0, 0])
        expectEqual(report.counters.hitches, 4)
        expectEqual(report.counters.missedFrames, 1 + 3 + 7 + 19)
        expectEqual(report.worstHitches.map(\.gapMS), [200, 80, 40, 20])
    }

    // Scroll flag and phase only on the frames the source marks.
    do {
        var recorder = FrameHitchRecorder(origin: 0)
        recorder.frame(timestamp: 0, duration: 0.01, scrolling: false)
        recorder.frame(timestamp: 0.01, duration: 0.01, scrolling: true, phase: "momentum")
        recorder.frame(timestamp: 0.05, duration: 0.01, scrolling: true, phase: "momentum")
        recorder.frame(timestamp: 0.06, duration: 0.01, scrolling: false)
        recorder.frame(timestamp: 0.1, duration: 0.01, scrolling: false)
        let report = recorder.report()
        expectEqual(counts(report.counters), [4, 2, 2, 1, 6, 3])
        expectEqual(report.worstHitches.map(\.scrolling), [true, false])
        expectEqual(report.worstHitches.map(\.phase), ["momentum", nil])
    }

    // The worst list keeps the largest gaps; counters and blame keep every hitch.
    do {
        var recorder = FrameHitchRecorder(origin: 0)
        var time = 0.0
        recorder.frame(timestamp: time, duration: 0.01, scrolling: false)
        for index in 1...75 {
            let gap = 0.02 + Double(index) * 0.001
            recorder.work(stage: "stall", start: time + 0.001, end: time + gap - 0.001)
            time += gap
            recorder.frame(timestamp: time, duration: 0.01, scrolling: false)
            time += 0.01
            recorder.frame(timestamp: time, duration: 0.01, scrolling: false)
        }
        let report = recorder.report()
        expectEqual(report.worstHitches.count, 60)
        expectEqual(report.worstHitches.first?.gapMS, 95)
        expectEqual(report.worstHitches.last?.gapMS, 36)
        expectTrue(zip(report.worstHitches, report.worstHitches.dropFirst()).allSatisfy { $0.gapMS >= $1.gapMS })
        expectEqual(report.counters.hitches, 75)
        expectEqual(report.blame.first?.stage, "stall")
        expectEqual(report.blame.first?.hitches, 75)
    }

    // A wrapped ring attributes only what it retained and says so; a window
    // after the oldest retained interval is complete.
    do {
        var recorder = FrameHitchRecorder(origin: 0, journalCapacity: 4)
        recorder.frame(timestamp: 5, duration: 0.01, scrolling: false)
        for index in 0..<6 {
            let start = 5 + Double(index) * 0.01
            recorder.work(stage: "work\(index)", start: start, end: start + 0.01)
        }
        expectEqual(recorder.retainedWork.map(\.stage), ["work2", "work3", "work4", "work5"])
        let truncated = recorder.frame(timestamp: 5.1, duration: 0.01, scrolling: false)
        expectEqual(truncated?.work.map(\.stage).sorted(), ["work2", "work3", "work4", "work5"])
        expectEqual(truncated?.attributedMS, 40)
        expectEqual(truncated?.unattributedMS, 60)
        expectEqual(truncated?.journalTruncated, true)
        recorder.frame(timestamp: 5.11, duration: 0.01, scrolling: false)
        recorder.work(stage: "work6", start: 5.115, end: 5.12)
        let complete = recorder.frame(timestamp: 5.2, duration: 0.01, scrolling: false)
        expectEqual(complete?.work.map(\.stage), ["work6"])
        expectEqual(complete?.journalTruncated, false)
        let journal = recorder.report().journal
        expectEqual([journal.capacity, journal.recorded, journal.retained, journal.dropped], [4, 7, 4, 3])
    }

    // Chain breaks, repeated callbacks and missing intervals never count as hitches.
    do {
        var recorder = FrameHitchRecorder()
        expectTrue(recorder.isEmpty)
        recorder.frame(timestamp: 1, duration: 0.01, scrolling: false)
        recorder.frame(timestamp: 1, duration: 0.01, scrolling: false)
        recorder.frame(timestamp: 0.5, duration: 0.01, scrolling: false)
        recorder.breakChain()
        recorder.frame(timestamp: 60, duration: 0.01, scrolling: false)
        recorder.frame(timestamp: 61, duration: 0, scrolling: false)
        recorder.frame(timestamp: 61.01, duration: 0.01, scrolling: false)
        let report = recorder.report()
        expectEqual(counts(report.counters), [1, 0, 0, 0, 0, 0])
        expectEqual(recorder.origin, 1)
        expectEqual(report.recordingMS, 60_010)
        expectFalse(recorder.isEmpty)
    }

    // The report is plain JSON with stable snake_case keys and round-trips.
    do {
        var recorder = FrameHitchRecorder(origin: 0)
        recorder.frame(timestamp: 0, duration: 0.01, scrolling: false)
        recorder.work(stage: "calibration_stall", start: 0.001, end: 0.121, detail: "120ms")
        recorder.frame(timestamp: 0.13, duration: 0.01, scrolling: true, phase: "wheel")
        let report = recorder.report()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        expectEqual(try JSONDecoder().decode(FrameHitchRecorder.Report.self, from: data), report)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        expectEqual(object.map { Set($0.keys) }, ["recording_ms", "display_interval_ms", "counters", "gap_histogram",
                                                   "worst_hitches", "blame", "unattributed_ms", "journal"])
        let text = String(decoding: data, as: UTF8.self)
        for key in ["\"missed_frames\"", "\"scrolling_hitches\"", "\"by_interval\"", "\"by_ms\"", "\"gap_ms\"", "\"start_ms\"",
                    "\"inclusive_ms\"", "\"attributed_ms\"", "\"other_stages_ms\"", "\"journal_truncated\"",
                    "\"calibration_stall\"", "\"120ms\""] {
            precondition(text.contains(key), "report JSON lacks \(key)")
        }
        let histogram = (object?["gap_histogram"] as? [String: Any])?["by_interval"] as? [[String: Any]]
        expectEqual(histogram?.count, 5)
        expectTrue(histogram?.last?["upper"] == nil)
        expectEqual((histogram?.first?["upper"] as? NSNumber)?.doubleValue, 1.5)
    }
    print("PASS: frame hitch recorder — steady frames, long gap, nested/partial attribution, scroll flag, histogram, worst-60 cap, ring overwrite, chain breaks, JSON report")
}
