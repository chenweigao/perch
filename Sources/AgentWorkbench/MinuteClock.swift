import Observation
import SwiftUI
import WorkbenchCore

/// One shared minute tick for every time label. Each row used to own a `TimelineView`,
/// so a long session list kept hundreds of timers alive. A label reads `now` (relative
/// ages such as "25 分钟前") or `day` (sidebar times such as "14:32", "昨天") inside its
/// own body, so a tick re-evaluates only the labels that can change; the timer runs only
/// while a label is on screen.
@MainActor @Observable final class MinuteClock {
    static let shared = MinuteClock()
    private(set) var now = Date()
    /// The start of today; changes once a day, not on every tick.
    private(set) var day = Calendar.current.startOfDay(for: Date())
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var users = 0

    func retain() {
        users += 1
        guard timer == nil else { return }
        tick()
        let boundary = Calendar.current.nextDate(after: now, matching: DateComponents(second: 0),
                                                 matchingPolicy: .nextTime) ?? now.addingTimeInterval(60)
        let timer = Timer(fire: boundary, interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        timer?.invalidate(); timer = nil
    }
    private func tick() {
        now = Date()
        let today = Calendar.current.startOfDay(for: now)
        if today != day { day = today }
    }
}

/// A session's update time, kept current by the shared clock.
struct SessionTimeText: View {
    enum Tone { case quiet, tertiary }
    let updatedAt: Double
    var compact = true
    var tone = Tone.quiet
    @Environment(\.locale) private var locale
    var body: some View {
        let text = Text(label)
            .font(.system(size: WorkbenchTheme.Typography.caption)).monospacedDigit().lineLimit(1)
        Group {
            switch tone {
            case .quiet: text.foregroundStyle(WorkbenchTheme.quiet)
            case .tertiary: text.foregroundStyle(.tertiary)
            }
        }.fixedSize().onAppear { MinuteClock.shared.retain() }.onDisappear { MinuteClock.shared.release() }
    }
    /// Sidebar times change with the day, relative ages with the minute.
    private var label: String {
        if compact {
            _ = MinuteClock.shared.day
            return SessionTime.compactLabel(since: updatedAt, locale: locale) ?? ""
        }
        return SessionTime.label(since: updatedAt, waiting: false, now: MinuteClock.shared.now) ?? ""
    }
}
