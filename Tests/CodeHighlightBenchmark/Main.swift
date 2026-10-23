import AppKit
import Darwin

@main struct HighlightSchedulingBenchmark {
    static func main() async throws {
        let input = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let repeated = String(repeating: input, count: (4 * 1_048_576 / input.utf8.count) + 1)
        let source = String(decoding: Array(repeated.utf8.prefix(4 * 1_048_576)), as: UTF8.self)
        let largeEngine = CodeHighlighter.engine(for: source)
        let small = "let immediate = \"中文 👩🏽‍💻\" // selected file\n"
        let start = ProcessInfo.processInfo.systemUptime
        let large = Task { try await largeEngine.highlight(source, language: "python") }
        try await Task.sleep(for: .milliseconds(60))
        let smallStart = ProcessInfo.processInfo.systemUptime
        _ = try await CodeHighlighter.engine(for: small).highlight(small, language: "swift")
        let smallMS = (ProcessInfo.processInfo.systemUptime - smallStart) * 1000
        let first = try await large.value
        let coldMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let count = await largeEngine.parseCount
        let warmStart = ProcessInfo.processInfo.systemUptime
        let second = try await largeEngine.highlight(source, language: "python")
        let warmMS = (ProcessInfo.processInfo.systemUptime - warmStart) * 1000
        let after = await largeEngine.parseCount
        precondition(first.count == second.count && NSMaxRange(first.last!.range) == source.utf16.count)
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let result: [String: Any] = ["small_during_large_ms": smallMS, "cold_large_ms": coldMS,
            "repeat_large_ms": warmMS, "repeat_reparsed": after != count,
            "source_bytes": source.utf8.count, "tokens": first.count,
            "cache_bytes": await largeEngine.cacheBytes, "peak_rss_bytes": usage.ru_maxrss]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
