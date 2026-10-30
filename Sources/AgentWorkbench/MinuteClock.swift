import Observation
import SwiftUI
import WorkbenchCore

/// One shared minute tick for every relative-time label ("25分", "3时"). Each row used
/// to own a `TimelineView`, so a long session list kept hundreds of timers alive. A label
/// reads `now` inside its own body, so a tick re-evaluates the labels and nothing else;
/// the timer runs only while a label is on screen.
@MainActor @Observable final class MinuteClock {
    static let shared = MinuteClock()
    private(set) var now = Date()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var users = 0

    func retain() {
        users += 1
        guard timer == nil else { return }
        now = Date()
        let boundary = Calendar.current.nextDate(after: now, matching: DateComponents(second: 0),
                                                 matchingPolicy: .nextTime) ?? now.addingTimeInterval(60)
        let timer = Timer(fire: boundary, interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        timer?.invalidate(); timer = nil
    }
}

/// A session's age, kept current by the shared clock.
struct SessionTimeText: View {
    enum Tone { case quiet, tertiary }
    let updatedAt: Double
    var compact = true
    var tone = Tone.quiet
    @Environment(\.locale) private var locale
    var body: some View {
        let now = MinuteClock.shared.now
        let text = Text(compact ? SessionTime.compactLabel(since: updatedAt, now: now, locale: locale) ?? ""
                                : SessionTime.label(since: updatedAt, waiting: false, now: now) ?? "")
            .font(.system(size: WorkbenchTheme.Typography.caption)).monospacedDigit().lineLimit(1)
        Group {
            switch tone {
            case .quiet: text.foregroundStyle(WorkbenchTheme.quiet)
            case .tertiary: text.foregroundStyle(.tertiary)
            }
        }.fixedSize().onAppear { MinuteClock.shared.retain() }.onDisappear { MinuteClock.shared.release() }
    }
}
