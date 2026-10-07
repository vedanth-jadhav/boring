import Foundation

struct CodexTokenTotals: Codable, Equatable, Sendable {
    var input: Int64 = 0
    var cached: Int64 = 0
    var cacheWrite: Int64 = 0
    var output: Int64 = 0
    var reasoning: Int64 = 0
    var total: Int64 { input + output }

    init() {}

    init(_ value: [String: Any]) {
        func count(_ key: String) -> Int64 { max(0, (value[key] as? NSNumber)?.int64Value ?? 0) }
        input = count("input_tokens")
        cached = min(input, count("cached_input_tokens"))
        cacheWrite = min(input - cached, count("cache_write_input_tokens"))
        output = count("output_tokens")
        reasoning = min(output, count("reasoning_output_tokens"))
    }

    func delta(from previous: Self) -> Self {
        var result = Self()
        result.input = max(0, input - previous.input)
        result.cached = min(result.input, max(0, cached - previous.cached))
        result.cacheWrite = min(result.input - result.cached, max(0, cacheWrite - previous.cacheWrite))
        result.output = max(0, output - previous.output)
        result.reasoning = min(result.output, max(0, reasoning - previous.reasoning))
        return result
    }

    mutating func add(_ other: Self) {
        input += other.input; cached += other.cached; cacheWrite += other.cacheWrite
        output += other.output; reasoning += other.reasoning
    }

    static func compact(_ count: Int64) -> String {
        if count >= 1_000_000_000 { return String(format: "%.2fB", Double(count) / 1_000_000_000) }
        if count >= 1_000_000 { return String(format: "%.2fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return count.formatted()
    }
}
