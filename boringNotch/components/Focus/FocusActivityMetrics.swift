import AppKit

/// Reserve tabular digit widths, rather than an arbitrary activity width. A
/// countdown never relayouts just because 09 became 08.
@MainActor
enum FocusActivityMetrics {
    static let font: NSFont = {
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        guard let rounded = digits.fontDescriptor.withDesign(.rounded),
              let font = NSFont(descriptor: rounded, size: 12) else { return digits }
        return font
    }()

    static func width(for duration: TimeInterval) -> CGFloat {
        let sample = FocusSessionSnapshot.timeText(duration)
        let textWidth = (sample as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        return textWidth + 20 + 6 + 16
    }
}
