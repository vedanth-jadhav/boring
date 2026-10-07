import AppKit

enum CodexActivityMetrics {
    static let headerWidth: CGFloat = 62
    static let height: CGFloat = 26

    /// Reserve the longest valid value so a minute tick never moves the pill.
    static func width(limit: CodexPillLimit, metric: CodexPillMetric, showsLabel: Bool = true, expanded: Bool = false) -> CGFloat {
        let label = showsLabel ? (limit.shortTitle as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width + 6 : 0
        let sample: String
        switch metric {
        case .remaining: sample = "100%"
        case .used: sample = "100% used"
        case .reset: sample = limit == .session ? "23h 59m" : "6d 23h"
        case .remainingAndReset: sample = limit == .session ? "100% · 23h 59m" : "100% · 6d 23h"
        }
        let value = (sample as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)]).width
        return ceil(label + value + (expanded ? 4 : 20))
    }
}
