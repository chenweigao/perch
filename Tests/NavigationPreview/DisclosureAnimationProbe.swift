import AppKit
import QuartzCore
import SwiftUI

/// Frame-sampling probe for WorkbenchDisclosureContent's height transition
/// (docs/design/disclosure-animation.md). State-level observers only see
/// endpoints, so a zero-height NSView sibling is sampled on a timer: its Y
/// tracks the container's animated bottom edge frame by frame.
@MainActor
final class DisclosureProbeModel: ObservableObject {
    var heights: [(time: Double, offset: CGFloat)] = []
    var mountEvents: [(time: Double, mounted: Bool)] = []
    weak var probeView: NSView?
    @Published var expanded = false
    func record(offset: CGFloat) {
        let now = CACurrentMediaTime()
        if heights.last?.offset != offset { heights.append((now, offset)) }
    }
    func record(mounted: Bool) { mountEvents.append((CACurrentMediaTime(), mounted)) }
}

struct DisclosureProbeView: View {
    @ObservedObject var model: DisclosureProbeModel
    let reduceMotion: Bool
    var body: some View {
        VStack(spacing: 0) {
            WorkbenchDisclosureContent(expanded: model.expanded) {
                Color.accentColor.frame(height: 120)
                    .onAppear { model.record(mounted: true) }
                    .onDisappear { model.record(mounted: false) }
            }
            HeightProbeView(model: model).frame(height: 0)
        }
        .environment(\.conversationReduceMotion, reduceMotion)
        .fixedSize()
        .frame(width: 320)
    }
}

private struct HeightProbeView: NSViewRepresentable {
    let model: DisclosureProbeModel
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        model.probeView = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension NavigationRunner {
    /// Toggle expand/collapse around a real animation and assert the contract:
    /// intermediate offsets exist, content stays mounted through the collapse,
    /// and Reduce Motion bypasses both.
    @MainActor
    func disclosureAnimation() async throws -> [String: Any] {
        func phase(reduceMotion: Bool) async -> (model: DisclosureProbeModel, collapseAt: Double) {
            let model = DisclosureProbeModel()
            let probe = DisclosureProbeView(model: model, reduceMotion: reduceMotion)
            let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 340, height: 220),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = reduceMotion ? "probe-reduced" : "probe-animated"
            window.contentView = NSHostingView(rootView: probe)
            window.isReleasedWhenClosed = false
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            // Per-tick sampling of the probe's Y: distinct offsets = frames.
            let sampler = Timer.scheduledTimer(withTimeInterval: 0.008, repeats: true) { _ in
                guard let probe = model.probeView else { return }
                model.record(offset: probe.convert(NSPoint.zero, to: nil).y)
            }
            defer { sampler.invalidate() }
            try? await Task.sleep(for: .milliseconds(600))
            model.expanded = true
            try? await Task.sleep(for: .milliseconds(900))
            let collapseAt = CACurrentMediaTime()
            model.expanded = false
            try? await Task.sleep(for: .milliseconds(900))
            return (model, collapseAt)
        }

        let animated = await phase(reduceMotion: false)
        let reduced = await phase(reduceMotion: true)

        func intermediates(_ model: DisclosureProbeModel) -> Int {
            let values = model.heights.map(\.offset)
            guard let first = values.first, let last = values.last else { return 0 }
            return Set(values.filter { $0 != first && $0 != last }).count
        }
        let expandIntermediates = intermediates(animated.model)
        let reducedIntermediates = intermediates(reduced.model)
        let unmountAt = animated.model.mountEvents.last(where: { !$0.mounted })?.time ?? animated.collapseAt
        let mountedThroughCollapseMs = (unmountAt - animated.collapseAt) * 1000

        var failures: [String] = []
        if expandIntermediates < 2 { failures.append("expand showed \(expandIntermediates) intermediate heights") }
        if reducedIntermediates > 0 { failures.append("reduce-motion still produced \(reducedIntermediates) intermediate heights") }
        if mountedThroughCollapseMs < 150 { failures.append("content unmounted \(Int(mountedThroughCollapseMs))ms into the close animation") }
        if !failures.isEmpty {
            throw NavigationError("disclosure animation: " + failures.joined(separator: "; "))
        }
        return ["disclosure_animation": [
            "expand_intermediate_offsets": expandIntermediates,
            "reduce_motion_intermediate_offsets": reducedIntermediates,
            "collapse_mounted_ms": Int(mountedThroughCollapseMs),
        ]]
    }
}
