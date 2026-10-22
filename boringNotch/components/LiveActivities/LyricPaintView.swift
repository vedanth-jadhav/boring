import AppKit
import QuartzCore

/// The display link never owns this view. Hidden, paused and silent rows do
/// not schedule frames, and lyric repainting never re-enters SwiftUI layout.
final class LyricPaintView: NSView {
    #if LYRIC_RENDER_CHECKS
    static var frameTicks = 0
    static var paintCount = 0
    #endif
    private final class LinkTarget: NSObject {
        weak var view: LyricPaintView?
        @objc func tick(_ link: CADisplayLink) { view?.frameTick() }
    }
    private let target = LinkTarget()
    private var link: CADisplayLink?
    private var configuration: LyricCanvasView?
    private var position = 0.0
    var isAnimating: Bool { link?.isPaused == false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        target.view = self
        NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ configuration: LyricCanvasView) {
        self.configuration = configuration
        position = configuration.position(at: .now)
        needsDisplay = true
        updateClock()
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    private func updateClock() {
        guard let configuration, let window, !isHiddenOrHasHiddenAncestor,
              window.occlusionState.contains(.visible), configuration.row.shouldAnimate(
                at: configuration.position(at: .now), rate: configuration.playbackRate,
                playing: configuration.isPlaying, reduceMotion: configuration.reduceMotion) else {
            link?.isPaused = true
            return
        }
        if link == nil {
            let displayLink = displayLink(target: target, selector: #selector(LinkTarget.tick(_:)))
            displayLink.add(to: .main, forMode: .common)
            link = displayLink
        }
        let rate = Float(1 / configuration.row.animationInterval(rate: configuration.playbackRate))
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: rate / 2, maximum: rate, preferred: rate)
        link?.isPaused = false
    }

    private func frameTick() {
        #if LYRIC_RENDER_CHECKS
        Self.frameTicks += 1
        #endif
        guard let configuration else { stop(); return }
        position = configuration.position(at: .now)
        needsDisplay = true
        if !configuration.row.shouldAnimate(at: position, rate: configuration.playbackRate,
            playing: configuration.isPlaying, reduceMotion: configuration.reduceMotion) { link?.isPaused = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        #if LYRIC_RENDER_CHECKS
        Self.paintCount += 1
        #endif
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        configuration?.draw(in: context, size: bounds.size, at: position)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else { refreshVisibility() }
    }
    override func viewDidHide() { super.viewDidHide(); link?.isPaused = true }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshVisibility() }
    @objc private func visibilityChanged() { refreshVisibility() }
    private func refreshVisibility() {
        if let configuration { position = configuration.position(at: .now); needsDisplay = true }
        updateClock()
    }

    deinit {
        link?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}
