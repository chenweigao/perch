import Foundation

enum Round36ReviewTrace {
    static var counters: [String: Int] = [:]
    static func hit(_ event: String) { counters[event, default: 0] += 1 }
    static func output() {
        for key in counters.keys.sorted() { print("TRACE: \(key)=\(counters[key]!)") }
        precondition(counters.keys.contains { $0.hasPrefix("adopt-fold-true-consumedRows-") })
        precondition(counters.keys.contains { $0.hasPrefix("adopt-fold-false-consumedRows-") })
        precondition(counters["consumed-prefix-verified",default:0] > 0)
    }
}
