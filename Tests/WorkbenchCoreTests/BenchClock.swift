import Foundation
#if canImport(QuartzCore)
import QuartzCore
#endif

/// Monotonic seconds for bench timing: CACurrentMediaTime on Apple platforms,
/// the dispatch uptime clock elsewhere.
func benchNow() -> Double {
#if canImport(QuartzCore)
    return CACurrentMediaTime()
#else
    return Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
#endif
}
