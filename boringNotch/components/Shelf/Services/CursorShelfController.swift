import AppKit
import Defaults
import SwiftUI

@MainActor
final class CursorShelfController {
    static let shared = CursorShelfController()
    let model = CursorShelfModel()
    private var panel: NSPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hoverTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var mouseIsDown = false
    private var trackingTimer: Timer?
    private var trackingBegan: TimeInterval = 0
    private var initialPasteboardCount = -1
    private var completedPasteboardCount = -1
    private var contentLatched = false
    private var samples: [(TimeInterval, CGPoint)] = []
    private var presentedForDrag = false
    private var lastProbe: TimeInterval = 0

    func start() {
        guard globalMonitor == nil else { return }
        completedPasteboardCount = NSPasteboard(name: .drag).changeCount
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.handle(event) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
        dismissTask?.cancel()
        trackingTimer?.invalidate(); trackingTimer = nil
        dismiss()
        mouseIsDown = false
        samples.removeAll()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dismissTask?.cancel()
            dismiss()
            mouseIsDown = true
            // Global callbacks can arrive after the source has already written
            // its new drag. Compare with the completed gesture, not a late
            // snapshot of the drag currently in flight.
            initialPasteboardCount = completedPasteboardCount
            lastProbe = 0
            Log.shelf.debug("Cursor down baseline \(self.initialPasteboardCount, privacy: .public), current \(NSPasteboard(name: .drag).changeCount, privacy: .public)")
            contentLatched = false
            presentedForDrag = false
            samples.removeAll(keepingCapacity: true)
            startTracking()
        case .leftMouseDragged:
            trackDrag(at: position(for: event), timestamp: ProcessInfo.processInfo.systemUptime)
        case .leftMouseUp:
            Log.shelf.debug("Cursor up: buttons \(NSEvent.pressedMouseButtons, privacy: .public)")
            // AppKit may synthesize an up when the source hands control to
            // its dragging session. The physical release is polled as well.
            if NSEvent.pressedMouseButtons & 1 == 0 { finishGesture() }
        case .keyDown:
            if event.keyCode == 53 {
                trackingTimer?.invalidate(); trackingTimer = nil
                mouseIsDown = false
                dismiss(); presentedForDrag = true
            }
        default: break
        }
    }

    private func finishGesture() {
            trackingTimer?.invalidate(); trackingTimer = nil
            mouseIsDown = false
            completedPasteboardCount = NSPasteboard(name: .drag).changeCount
            samples.removeAll(keepingCapacity: true)
            dismissTask?.cancel()
            dismissTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                self?.dismiss()
                self?.completedPasteboardCount = NSPasteboard(name: .drag).changeCount
            }
    }

    private func startTracking() {
        trackingTimer?.invalidate()
        trackingBegan = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollGesture() }
        }
        trackingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pollGesture() {
        guard mouseIsDown else { trackingTimer?.invalidate(); trackingTimer = nil; return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - trackingBegan > 0.15, NSEvent.pressedMouseButtons & 1 == 0 {
            Log.shelf.debug("Cursor polling detected release")
            finishGesture()
            return
        }
        trackDrag(at: NSEvent.mouseLocation, timestamp: now)
    }

    private func trackDrag(at globalPoint: CGPoint, timestamp: TimeInterval) {
            guard mouseIsDown, Defaults[.boringShelf], Defaults[.shakeShelfTools] else { dismiss(); return }
            if panel?.isVisible == true {
                let point = globalPoint
                if let panel {
                    if !panel.frame.insetBy(dx: -80, dy: -80).contains(point) { dismiss() }
                    else { hover(CGPoint(x: point.x - panel.frame.minX, y: panel.frame.maxY - point.y)) }
                }
                return
            }
            guard !presentedForDrag else { return }
            let now = timestamp
            if !contentLatched, now - lastProbe > 0.05 {
                lastProbe = now
                let pasteboard = NSPasteboard(name: .drag)
                contentLatched = pasteboard.changeCount != initialPasteboardCount && Self.hasContent(pasteboard)
                if contentLatched { Log.shelf.debug("Cursor file drag latched at pasteboard \(pasteboard.changeCount, privacy: .public)") }
            }
            guard contentLatched else { return }
            let point = globalPoint
            Log.shelf.debug("Cursor sample \(point.x, privacy: .public), \(point.y, privacy: .public)")
            samples.append((now, point))
            samples.removeAll { now - $0.0 > 0.8 }
            if samples.count > 100 { samples.removeFirst(samples.count - 100) }
            if shaken() { show(at: point) }
    }

    private func position(for event: NSEvent) -> CGPoint {
        // Sampling the live cursor erases direction changes when callbacks
        // queue behind UI work. Use the position captured in each event.
        if let location = event.cgEvent?.location, let primary = NSScreen.screens.first {
            return CGPoint(x: location.x, y: primary.frame.maxY - location.y)
        }
        return NSEvent.mouseLocation
    }

    private func shaken() -> Bool {
        guard samples.count >= 5 else { return false }
        for axis in [0, 1] {
            let values = samples.map { axis == 0 ? $0.1.x : $0.1.y }
            var pivot = values[0], direction: CGFloat = 0, reversals = 0, travel: CGFloat = 0
            for value in values.dropFirst() {
                let delta = value - pivot
                guard abs(delta) >= 12 else { continue }
                let next: CGFloat = delta > 0 ? 1 : -1
                if direction != 0 && next != direction { reversals += 1 }
                travel += abs(delta)
                direction = next
                pivot = value
            }
            if reversals >= 3, travel >= 150, (values.max()! - values.min()!) >= 40 { return true }
        }
        return false
    }

    private func show(at point: CGPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
        if !ShelfToolService.shared.isWorking { ShelfToolFeedback.shared.dismiss() }
        presentedForDrag = true
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let origin = CGPoint(x: min(max(point.x - 210, visible.minX), visible.maxX - 420), y: min(max(point.y - 210, visible.minY), visible.maxY - 420))
        model.branch = nil; model.selected = nil
        model.count = max(1, Self.urls(NSPasteboard(name: .drag)).count)
        model.fileURLs = Self.urls(NSPasteboard(name: .drag))
        if model.fileURLs.isEmpty { model.fileURLs = [URL(fileURLWithPath: "/Screenshot.png")] }
        let panel = NSPanel(contentRect: CGRect(origin: origin, size: CGSize(width: 420, height: 420)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        // A nonzero native backing surface keeps WindowServer drag hit testing
        // over the transparent gaps between the glass targets.
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.001)
        panel.ignoresMouseEvents = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = CursorShelfDropView(rootView: CursorShelfView(model: model))
        host.controller = self
        host.registerForDraggedTypes([.fileURL, .png, .tiff])
        panel.contentView = host
        panel.registerForDraggedTypes([.fileURL, .png, .tiff])
        self.panel = panel
        SharingStateManager.shared.beginInteraction()
        panel.orderFrontRegardless()
    }

    func hover(_ point: CGPoint) {
        if model.branch != nil, hypot(point.x - 210, point.y - 210) < 42 {
            clearHover(); model.branch = nil; return
        }
        let tool = model.tool(at: point)
        guard model.selected != tool else { return }
        Log.shelf.debug("Cursor hover \(point.x, privacy: .public), \(point.y, privacy: .public): \(tool?.rawValue ?? "none", privacy: .public)")
        hoverTask?.cancel()
        model.selected = tool
        guard let tool, !tool.children.isEmpty else { return }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled, model.selected == tool else { return }
            model.branch = tool
            model.selected = nil
        }
    }

    func clearHover() { hoverTask?.cancel(); model.selected = nil }

    func accept(_ pasteboard: NSPasteboard) -> Bool {
        Log.shelf.debug("Cursor accept: \(self.model.selected?.rawValue ?? "none", privacy: .public)")
        completedPasteboardCount = pasteboard.changeCount
        trackingTimer?.invalidate(); trackingTimer = nil
        mouseIsDown = false
        guard let tool = model.selected else { dismiss(); return false }
        var urls = Self.urls(pasteboard)
        if urls.isEmpty, let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            do {
                let ext = pasteboard.availableType(from: [.png]) != nil ? "png" : "tiff"
                let destination = try ShelfFileLibrary.destination(named: "Screenshot.\(ext)", category: "Screenshots")
                try data.write(to: destination, options: .atomic)
                urls = [destination]
            } catch { dismiss(); ShelfToolService.shared.report(error); return false }
        }
        guard !urls.isEmpty else { dismiss(); return false }
        dismiss()
        ShelfToolService.shared.run(tool, urls: urls)
        return true
    }

    func dismiss() {
        hoverTask?.cancel()
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
        SharingStateManager.shared.endInteraction()
        model.selected = nil
    }

    private static func hasContent(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil
    }
    private static func urls(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
