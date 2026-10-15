import AppKit

/// A continuous input surface over the ruler, including spaces between ticks.
@MainActor
final class RulerMouseDrag: NSView {
    weak var scrollView: NSScrollView?
    var tickSpacing: CGFloat = 8
    var onChange: (Int) -> Void = { _ in }
    var onEnd: (Int) -> Void = { _ in }
    private var origin: CGFloat?
    private var mouseStart: CGFloat?
    override func draw(_ dirtyRect: NSRect) {
        // WindowServer passes fully clear pixels through before AppKit can hit-test them.
        NSColor.black.withAlphaComponent(0.01).setFill()
        dirtyRect.fill()
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .openHand)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelDrag() }
    }

    func cancelDrag() {
        if mouseStart != nil { NSCursor.arrow.set() }
        mouseStart = nil
        origin = nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        origin = scrollView?.contentView.bounds.minX
        mouseStart = event.locationInWindow.x
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseStart,
              let minute = move(translation: event.locationInWindow.x - mouseStart, tickSpacing: tickSpacing) else { return }
        onChange(minute)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseStart != nil else { return }
        mouseStart = nil
        (visibleRect.contains(convert(event.locationInWindow, from: nil)) ? NSCursor.openHand : .arrow).set()
        if let minute = end(tickSpacing: tickSpacing) { onEnd(minute) }
    }

    override func scrollWheel(with event: NSEvent) {
        // Preserve native phases, momentum and snapping for either trackpad axis.
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
              let source = event.cgEvent, let copy = source.copy() else {
            scrollView?.scrollWheel(with: event)
            return
        }
        for (vertical, horizontal) in [
            (CGEventField.scrollWheelEventDeltaAxis1, CGEventField.scrollWheelEventDeltaAxis2),
            (.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2),
            (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2)
        ] {
            copy.setIntegerValueField(horizontal, value: source.getIntegerValueField(vertical))
            copy.setIntegerValueField(vertical, value: 0)
        }
        let mapped = NSEvent(cgEvent: copy) ?? event
        scrollView?.scrollWheel(with: mapped)
    }

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
