import AppKit
import SwiftUI
import Defaults

extension Defaults.Keys {
    static let normalizeGestureDirection = Key<Bool>("ruler-check-direction", default: true)
    static let reduceGlass = Key<Bool>("ruler-check-glass", default: false)
    static let hideFromScreenRecording = Key<Bool>("ruler-check-recording", default: false)
    static let hideNonNotchedFromMissionControl = Key<Bool>("ruler-check-mission-control", default: false)
}

@MainActor enum FocusHaptics { static func detent(major: Bool) {} }

private final class InputCheckPanel: BoringNotchSkyLightWindow {
    var dispatchedClicks = 0
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { dispatchedClicks += 1 }
        super.sendEvent(event)
    }
}

// Quartz-created scroll events have no AppKit window; supply the real dispatch target.
private final class WindowScrollEvent: NSEvent {
    let source: NSEvent
    let targetWindow: NSWindow
    let point: NSPoint

    init(source: NSEvent, window: NSWindow, point: NSPoint) {
        self.source = source
        targetWindow = window
        self.point = point
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("Unavailable") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { targetWindow }
    override var windowNumber: Int { targetWindow.windowNumber }
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaX: CGFloat { source.scrollingDeltaX }
    override var scrollingDeltaY: CGFloat { source.scrollingDeltaY }
    override var phase: NSEvent.Phase { source.phase }
    override var momentumPhase: NSEvent.Phase { source.momentumPhase }
    override var hasPreciseScrollingDeltas: Bool { source.hasPreciseScrollingDeltas }
    override var cgEvent: CGEvent? { source.cgEvent }
}

@main struct DurationRulerChecks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await runChecks()
            NSApp.stop(nil)
            NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
        }
        NSApp.run()
    }

    @MainActor static func runChecks() async {
        let originalPointer = NSEvent.mouseLocation
        defer {
            CGWarpMouseCursorPosition(NSPoint(x: originalPointer.x,
                                             y: NSScreen.screens[0].frame.maxY - originalPointer.y))
        }
        var minutes = 40
        var buttonClicks = 0
        let shape = NotchShape(topCornerRadius: 19, bottomCornerRadius: 32)
        let host = NotchHostingView(rootView:
            LiquidGlassSurface(shape: shape, expanded: true, width: 640, height: 230) {
                VStack(spacing: 12) {
                    Color.clear.frame(height: 32)
                    DurationRuler(minutes: Binding(get: { minutes }, set: { minutes = $0 }))
                    HStack(spacing: 12) {
                        Button { buttonClicks += 1 } label: {
                            Text("Start Timer").frame(width: 140, height: 32).contentShape(Capsule())
                        }
                        Button { buttonClicks += 1 } label: {
                            Text("Edit apps").frame(width: 140, height: 32).contentShape(Capsule())
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 500)
            }
                .clipShape(shape)
                .contentShape(Rectangle())
                .contextMenu { Button("Settings") { } }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        )
        let panel = InputCheckPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 320),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 320)
        panel.setFrameOrigin(NSPoint(x: 20, y: 20))
        panel.orderFront(nil)
        defer { panel.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        await settle()
        guard let input = descendant(RulerMouseDrag.self, in: host), let scroll = input.scrollView else {
            fatalError("The real SwiftUI ruler must mount its native input and scroll view")
        }
        let behind = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 720, height: 100),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        behind.isReleasedWhenClosed = false
        let rulerCenter = panel.convertPoint(toScreen: input.convert(NSPoint(x: 250, y: 27), to: nil))
        behind.setFrame(NSRect(x: 20, y: rulerCenter.y - 150, width: 720, height: 150), display: true)
        behind.makeKeyAndOrderFront(nil)
        defer { behind.orderOut(nil) }
        await settle()
        expect(host.acceptsFirstMouse(for: nil), "SwiftUI controls accept clicks while another app is active")
        expect(input.acceptsFirstMouse(for: nil), "Ruler accepts the first press in an inactive panel")
        expect(input.bounds.width >= 499 && input.bounds.height == 54, "Input covers the entire ruler")
        for x in [CGFloat(2), 120, 250, 380, 498] {
            for y in [CGFloat(2), 27, 52] {
                let point = panel.convertPoint(toScreen: input.convert(NSPoint(x: x, y: y), to: nil))
                let target = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
                expect(target == panel.windowNumber, "Window server targets the notch over ruler at \(x),\(y) (got \(target), expected \(panel.windowNumber))")
            }
        }
        expect(NSWindow.windowNumber(at: panel.convertPoint(toScreen: NSPoint(x: 10, y: 10)),
                                     belowWindowWithWindowNumber: 0) != panel.windowNumber,
               "Transparent space outside the notch remains click-through")
        let previousMinutes = minutes
        let previousFrame = behind.frame
        for (type, offset) in [(CGEventType.leftMouseDown, CGFloat(0)), (.leftMouseDragged, -24), (.leftMouseUp, -24)] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: NSPoint(x: rulerCenter.x + offset, y: NSScreen.screens[0].frame.maxY - rulerCenter.y),
                mouseButton: .left)!
            event.post(tap: .cghidEventTap)
            await settle()
        }
        expect(minutes == previousMinutes + 3, "System-routed grab changes the timer across a background window resize edge (\(previousMinutes) to \(minutes))")
        expect(behind.frame == previousFrame, "Grabbing the ruler leaves the window behind it untouched")
        for horizontal in [true, false] {
            let before = minutes
            for phase: Int64 in [1, 2, 4] {
                let delta: Int32 = phase == 4 ? 0 : (horizontal ? -16 : 16)
                let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                    wheel1: horizontal ? 0 : delta, wheel2: horizontal ? delta : 0, wheel3: 0)!
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                event.location = NSPoint(x: rulerCenter.x, y: NSScreen.screens[0].frame.maxY - rulerCenter.y)
                event.post(tap: .cghidEventTap)
                await settle()
            }
            expect(horizontal ? minutes > before : minutes < before,
                   "System-routed \(horizontal ? "horizontal" : "vertical") scroll changes the timer over the window behind it")
            expect(behind.frame == previousFrame, "Scrolling the ruler leaves the background window frame untouched")
        }
        let bareHost = NotchHostingView(rootView: DurationRuler(minutes: .constant(60)))
        let barePanel = InputCheckPanel(contentRect: NSRect(x: 20, y: 20, width: 500, height: 54),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        barePanel.contentView = bareHost
        barePanel.orderFront(nil)
        await settle()
        for x in [CGFloat(2), 120, 250, 380, 498] {
            for y in [CGFloat(2), 27, 53] {
                let point = barePanel.convertPoint(toScreen: NSPoint(x: x, y: y))
                expect(NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == barePanel.windowNumber,
                       "The ruler itself owns blank pixels at \(x),\(y), independently of the glass backdrop")
            }
        }
        barePanel.orderOut(nil)
        for x in [CGFloat(2), 120, 250, 380, 498] {
            for y in [CGFloat(2), 27, 52] {
                let point = host.superview!.convert(NSPoint(x: x, y: y), from: input)
                expect(input.visibleRect.contains(NSPoint(x: x, y: y)), "Ruler monitoring covers \(x),\(y)")
                expect(host.hitTest(point) === input, "Blank space, tick gaps and faded edges receive input at \(x),\(y)")
            }
        }
        for x in [CGFloat(2), 120, 250, 380, 498] {
            for y in [CGFloat(2), 27, 52] {
                let before = minutes
                let start = input.convert(NSPoint(x: x, y: y), to: nil)
                dispatch(mouse(.leftMouseDown, point: start, panel: panel))
                dispatch(mouse(.leftMouseDragged, point: NSPoint(x: start.x - 8, y: start.y), panel: panel))
                dispatch(mouse(.leftMouseUp, point: NSPoint(x: start.x - 8, y: start.y), panel: panel))
                await settle()
                expect(minutes == before + 1, "Press and drag changes time from \(x),\(y), including outside the ruler")
            }
        }
        for horizontal in [true, false] {
            for x in [CGFloat(2), 250, 498] {
                let before = scroll.contentView.bounds.minX
                let minutesBefore = minutes
                for phase: Int64 in [1, 2, 4] {
                    let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                        wheel1: horizontal ? 0 : -24, wheel2: horizontal ? -24 : 0, wheel3: 0)!
                    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                    let point = input.convert(NSPoint(x: x, y: 27), to: nil)
                    event.location = NSPoint(x: panel.frame.minX + point.x, y: NSScreen.screens[0].frame.maxY - panel.frame.minY - point.y)
                    NSApp.sendEvent(WindowScrollEvent(source: NSEvent(cgEvent: event)!, window: panel, point: point))
                    await settle()
                }
                expect(scroll.contentView.bounds.minX > before && minutes > minutesBefore,
                       "\(horizontal ? "Horizontal" : "Vertical") trackpad scrolling changes time at x=\(x) (offset \(before) to \(scroll.contentView.bounds.minX), minutes \(minutesBefore) to \(minutes))")
            }
        }
        let start = input.convert(NSPoint(x: 250, y: 27), to: nil)
        for (translation, expected) in [(CGFloat(10_000), 1), (-10_000, 120)] {
            dispatch(mouse(.leftMouseDown, point: start, panel: panel))
            dispatch(mouse(.leftMouseDragged, point: NSPoint(x: start.x + translation, y: start.y), panel: panel))
            dispatch(mouse(.leftMouseUp, point: NSPoint(x: start.x + translation, y: start.y), panel: panel))
            await settle()
            expect(minutes == expected, "Dragging clamps to \(expected) minutes")
        }
        let dispatchedBefore = panel.dispatchedClicks
        for x in [input.bounds.midX - 76, input.bounds.midX + 76] {
            let point = input.convert(NSPoint(x: x, y: -28), to: nil)
            panel.acceptsMouseMovedEvents = true
            dispatch(mouse(.mouseMoved, point: point, panel: panel))
            await settle()
            dispatch(mouse(.leftMouseDown, point: point, panel: panel))
            await settle()
            dispatch(mouse(.leftMouseUp, point: point, panel: panel))
            await settle()
        }
        expect(buttonClicks == 2, "Start Timer and Edit apps buttons receive their first click")
        expect(panel.dispatchedClicks == dispatchedBefore + 2,
               "Clicks on Start Timer and Edit apps reach panel dispatch")
        expect(!panel.isKeyWindow, "Ruler input does not take keyboard focus")
        panel.contentView = nil
        print("All duration ruler checks passed.")
    }

    @MainActor static func dispatch(_ event: NSEvent) {
        NSApp.postEvent(event, atStart: true)
        if let queued = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.1), inMode: .default, dequeue: true) {
            NSApp.sendEvent(queued)
        }
    }

    @MainActor static func settle() async {
        try? await Task.sleep(for: .milliseconds(350))
    }

    @MainActor static func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
    }

    @MainActor static func mouse(_ type: NSEvent.EventType, point: NSPoint, panel: NSPanel) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                          windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        print("PASS: \(message)")
    }
}
