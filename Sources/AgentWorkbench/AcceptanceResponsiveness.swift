#if PERCH_ACCEPTANCE
import Foundation
import QuartzCore

/// Cooperative main-actor wake-up lateness, not display hitches or event-to-photon latency.
@MainActor final class AcceptanceResponsiveness {
    private var task: Task<Void, Never>?
    private var delays: [Double] = []
    func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                let due = CACurrentMediaTime() + 0.010
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                self?.delays.append(max(0, (CACurrentMediaTime() - due) * 1000))
            }
        }
    }
    func finish() -> [String: Any] {
        task?.cancel(); task = nil
        let values = delays.sorted()
        func percentile(_ p: Double) -> Double { values.isEmpty ? 0 : values[Int(Double(values.count - 1) * p)] }
        return ["sample_count": values.count, "p50_ms": percentile(0.5), "p95_ms": percentile(0.95),
                "p99_ms": percentile(0.99), "max_ms": values.last ?? 0,
                "over_16ms": values.filter { $0 > 16 }.count, "over_50ms": values.filter { $0 > 50 }.count,
                "boundary": "lateness after 10ms main-actor Task.sleep; includes OS scheduling; not frame or hardware input latency"]
    }
}
#endif
