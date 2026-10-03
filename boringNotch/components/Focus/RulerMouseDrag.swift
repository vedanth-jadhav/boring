import AppKit

/// Mouse scrubbing uses the native clip view. Trackpad gestures and momentum are
/// left entirely to NSScrollView/SwiftUI; no custom velocity or display-link loop.
@MainActor
final class RulerMouseDrag {
    weak var scrollView: NSScrollView?
    private var origin: CGFloat?

    func move(translation: CGFloat, tickSpacing: CGFloat) -> Int? {
        guard let scrollView, let document = scrollView.documentView else { return nil }
        let clip = scrollView.contentView
        if origin == nil { origin = clip.bounds.minX }
        let inset = (clip.bounds.width - tickSpacing) / 2
        let maxOffset = max(-inset, document.frame.width - clip.bounds.width + inset)
        let x = min(maxOffset, max(-inset, (origin ?? 0) - translation))
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.minY))
        scrollView.reflectScrolledClipView(clip)
        return centeredMinute(tickSpacing: tickSpacing)
    }

    func end(tickSpacing: CGFloat) -> Int? {
        defer { origin = nil }
        return centeredMinute(tickSpacing: tickSpacing)
    }
    private func centeredMinute(tickSpacing: CGFloat) -> Int? {
        guard let scrollView else { return nil }
        let clip = scrollView.contentView.bounds
        let centeredOffset = clip.minX + (clip.width - tickSpacing) / 2
        return min(120, max(1, Int((centeredOffset / tickSpacing).rounded()) + 1))
    }
}
