#if PERCH_ACCEPTANCE
import AppKit
import QuartzCore
import WorkbenchCore

/// Exercises the mounted NSTextInputClient and production draft delegate. It does
/// not emulate a physical keyboard, an input-method candidate panel or the display.
@MainActor enum InputAcceptance {
    static func run(window: NSWindow, draft: () -> String, readerEvaluations: () -> Int,
                    stream: (Int) async throws -> Void) async throws -> [String: Any] {
        func editor(in view: NSView?) -> DraftTextView? {
            guard let view else { return nil }
            if let field = view as? DraftTextView, field.window === window, field.isEditable,
               !field.isHiddenOrHasHiddenAncestor { return field }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        func transcript(in view: NSView?) -> NSScrollView? {
            guard let view else { return nil }
            if let scroll = view as? NSScrollView, ConversationTranscript.navigator(in: scroll) != nil { return scroll }
            return view.subviews.lazy.compactMap { transcript(in: $0) }.first
        }
        func flush() { window.contentView?.layoutSubtreeIfNeeded(); window.contentView?.displayIfNeeded(); CATransaction.flush() }
        func settle(_ ready: () -> Bool) async throws {
            let start = CACurrentMediaTime()
            repeat {
                try await Task.sleep(for: .milliseconds(1)); flush()
                if ready() { return }
            } while CACurrentMediaTime() - start < 5
            throw WorkbenchError("Mounted input readiness timeout")
        }
        guard let field = editor(in: window.contentView), let scroll = transcript(in: window.contentView),
              let navigator = ConversationTranscript.navigator(in: scroll), window.makeFirstResponder(field) else {
            throw WorkbenchError("Missing mounted editor or transcript")
        }
        navigator.select(80)
        try await settle { navigator.current == 80 }
        field.setSelectedRange(NSRange(location: 0, length: field.string.utf16.count))
        field.insertText("前文 ", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await settle { draft() == "前文 " }
        try await Task.sleep(for: .milliseconds(200))
        let stall = ProcessInfo.processInfo.environment["PERCH_ACCEPTANCE_INPUT_STALL"] == "1"
        var samples: [[String: Any]] = []
        var maximumAnchorDrift = 0.0
        for index in 0..<24 {
            guard let anchor = ConversationTranscript.readingAnchor(in: scroll) else { throw WorkbenchError("Missing input reading anchor") }
            let plainBefore = readerEvaluations()
            let plainStart = CACurrentMediaTime()
            let expectedPlain = draft() + "a"
            field.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
            let plainDispatch = (CACurrentMediaTime() - plainStart) * 1000
            try await settle { draft() == expectedPlain && field.string == expectedPlain }
            let plainLayout = (CACurrentMediaTime() - plainStart) * 1000
            let plainInvalidations = readerEvaluations() - plainBefore
            let committed = draft()
            let markStart = CACurrentMediaTime()
            field.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            field.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            flush()
            let markLayout = (CACurrentMediaTime() - markStart) * 1000
            let marked = field.string
            guard field.hasMarkedText(), draft() == committed,
                  !field.handleReturn(keyCode: 36, modifiers: []) else { throw WorkbenchError("Composition leaked or consumed Return") }
            let streamStart = CACurrentMediaTime()
            try await stream(index)
            try await Task.sleep(for: .milliseconds(10)); flush()
            let streamLayout = (CACurrentMediaTime() - streamStart) * 1000
            guard field.hasMarkedText(), field.string == marked, draft() == committed else {
                throw WorkbenchError("Streaming overwrote marked text or committed draft")
            }
            let commitBefore = readerEvaluations()
            let commitStart = CACurrentMediaTime()
            if stall && index == 12 { usleep(80_000) } // Known delay validates this measurement boundary.
            field.insertText("中文 ", replacementRange: NSRange(location: NSNotFound, length: 0))
            let commitDispatch = (CACurrentMediaTime() - commitStart) * 1000
            try await settle { !field.hasMarkedText() && draft() == committed + "中文 " && field.string == draft() }
            let commitLayout = (CACurrentMediaTime() - commitStart) * 1000
            guard let after = ConversationTranscript.readingAnchor(in: scroll), after.entry == anchor.entry else {
                throw WorkbenchError("Input/streaming changed the reading entry")
            }
            let drift = abs(after.offset - anchor.offset)
            maximumAnchorDrift = max(maximumAnchorDrift, drift)
            guard drift <= 1 else { throw WorkbenchError("Input/streaming moved the reading anchor by \(drift) points") }
            samples.append(["index": index, "plain_dispatch_ms": plainDispatch, "plain_layout_ms": plainLayout,
                "marked_layout_ms": markLayout, "stream_layout_ms": streamLayout,
                "commit_dispatch_ms": commitDispatch, "commit_layout_ms": commitLayout,
                "plain_reader_evaluations": plainInvalidations, "commit_reader_evaluations": readerEvaluations() - commitBefore])
            try await Task.sleep(for: .milliseconds(50))
        }
        let controlDetected = (samples[12]["commit_dispatch_ms"] as! Double) >= 70
        if stall && !controlDetected { throw WorkbenchError("Input delay positive control was not detected") }
        let metrics = ["plain_dispatch_ms", "plain_layout_ms", "marked_layout_ms", "stream_layout_ms", "commit_dispatch_ms", "commit_layout_ms"]
        let summary = Dictionary(uniqueKeysWithValues: metrics.map { name in
            let values = samples.map { $0[name] as! Double }.sorted()
            return (name, ["count": Double(values.count), "median": values[values.count / 2],
                           "p95": values[Int(Double(values.count - 1) * 0.95)], "max": values.last!])
        })
        return ["input_samples": samples, "input_metrics": summary, "input_composition_cycles": samples.count,
            "input_marked_text_preserved": true, "input_max_anchor_drift_points": maximumAnchorDrift,
            "input_positive_control": stall, "input_positive_control_detected": stall && controlDetected,
            "input_boundary": "Mounted NSTextInputClient insertText/setMarkedText through production delegate and layout flush. Layout samples include a >=1ms async readiness wait; streaming samples include a 10ms UI settle. Excludes hardware events, actual IME candidate UI, compositor/display latency, network and FPS."]
    }
}
#endif
