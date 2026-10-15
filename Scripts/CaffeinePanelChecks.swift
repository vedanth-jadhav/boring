import AppKit
import Defaults
import SwiftUI

private let inputDefaults = UserDefaults(suiteName: "boring.caffeine-panel-checks")!
extension Defaults.Keys {
    static let normalizeGestureDirection = Key<Bool>("normalizeGestureDirection", default: true, suite: inputDefaults)
    static let reduceGlass = Key<Bool>("reduceGlass", default: false, suite: inputDefaults)
    static let hideFromScreenRecording = Key<Bool>("hideFromScreenRecording", default: false, suite: inputDefaults)
    static let hideNonNotchedFromMissionControl = Key<Bool>("hideNonNotchedFromMissionControl", default: false, suite: inputDefaults)
}

@MainActor private struct PanelFixture: View {
    @ObservedObject private var selection = FocusSessionManager.shared.selection
    private let shape = NotchShape(topCornerRadius: 19, bottomCornerRadius: 32)
    var body: some View {
        LiquidGlassSurface(shape: shape, expanded: true, width: 640,
                           height: selection.needsCaffeineSetup(isActive: false) ? 440 : 290) {
            VStack(spacing: 0) {
                Color.clear.frame(height: 38)
                FocusTimerView()
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .environment(\.appearsActive, true)
        .environment(\.colorScheme, .dark)
        .clipShape(shape).contentShape(Rectangle())
        .gesture(TapGesture().onEnded {}, including: .subviews)
        .panGesture(direction: .down, isEnabled: false) { _, _ in }
        .panGesture(direction: .up, isEnabled: false) { _, _ in }
        .panGesture(direction: .left, isEnabled: false) { _, _ in }
        .panGesture(direction: .right, isEnabled: false) { _, _ in }
        .contextMenu { Button("Settings") {} }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            GeometryReader { geometry in
                Button("Usage") {}.frame(width: 80, height: 28)
                    .position(x: geometry.size.width - 80, y: 20)
            }
        }
        .overlay { GeometryReader { _ in if false { Button("Timer activity") {} } } }
    }
}

// Keep the production panel/responder code, without taking the user's keyboard focus.
private final class FixturePanel: BoringNotchSkyLightWindow {
    private var keyForFixture = false
    override var isKeyWindow: Bool { keyForFixture }
    override func makeKey() { keyForFixture = true }
    override func orderOut(_ sender: Any?) { keyForFixture = false; super.orderOut(sender) }
}

@main struct CaffeinePanelChecks {
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
        defer { inputDefaults.removePersistentDomain(forName: "boring.caffeine-panel-checks") }
        let selection = FocusSessionManager.shared.selection
        selection.mode = .caffeine
        let host = NotchHostingView(rootView: PanelFixture())
        let panel = FixturePanel(contentRect: NSRect(x: -5000, y: -5000, width: 720, height: 490),
                                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.orderFront(nil)
        defer { panel.orderOut(nil) }
        await settle()
        let initialGlass = descendants(NSGlassEffectView.self, in: host).first
        for cycle in 0..<3 {
            guard let field = descendants(CaffeineSearchTextField.self, in: host).first else { fatalError("Search missing") }
            expect(field.bounds.height == 28, "Native search owns the full visible row height")
            let point = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
            await click(point, in: panel)
            guard let editor = field.currentEditor() as? NSTextView else { fatalError("Search click did not obtain editor in cycle \(cycle)") }
            expect(panel.keyboardFocus.inputResponder(in: panel) === editor && panel.isKeyWindow,
                   "Production search owns keyboard input in cycle \(cycle)")
            expect(!editor.drawsBackground && editor.backgroundColor == .clear, "Field editor stays transparent")
            let placeholderFont = field.placeholderAttributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            expect(placeholderFont == field.font && editor.font == field.font, "Placeholder and typed text share the same font metrics")
            if let cell = field.cell as? NSSearchFieldCell {
                let textRect = cell.searchTextRect(forBounds: field.bounds)
                expect(abs(textRect.midY - field.bounds.midY) <= 1,
                       "Native search text is vertically centered (text \(textRect), bounds \(field.bounds), size \(field.controlSize.rawValue))")
            }
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
            for (key, code) in [("B", UInt16(11)), ("r", 15), ("a", 0), ("v", 9), ("e", 14)] {
                panel.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key == "B" ? .shift : [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                    characters: key, charactersIgnoringModifiers: key.lowercased(), isARepeat: false, keyCode: code)!)
            }
            expect(field.stringValue == "Brave", "Typing reaches production app search")
            await settle()
            expect((field.delegate as? CaffeineSearchField.Coordinator)?.text.wrappedValue == "Brave",
                   "Production search binding receives the typed query")
            await clickButton("Timer", in: host, panel: panel)
            expect(selection.mode == .timer, "The real Timer mode button receives its first click")
            await settle()
            expect(!panel.wantsKeyForTextInput && !panel.isKeyWindow, "Switching modes releases search keyboard ownership")
            guard let input = descendants(RulerMouseDrag.self, in: host).first else { fatalError("Ruler missing") }
            let before = selection.minutes
            await click(input.convert(NSPoint(x: input.bounds.midX, y: 27), to: nil), in: panel, drag: -16)
            expect(selection.minutes == before + 2, "Production timer grab changes time")
            await clickButton("Caffeine", in: host, panel: panel)
            expect(selection.mode == .caffeine, "The real Caffeine mode button receives its first click")
            await settle()
            // The retained native ruler must not intercept events belonging to the new search.
            if let search = descendants(CaffeineSearchTextField.self, in: host).first {
                let point = search.convert(NSPoint(x: search.bounds.midX, y: search.bounds.midY), to: nil)
                let hit = host.hitTest(host.superview!.convert(point, from: nil))
                expect(hit === search || hit === search.currentEditor(),
                       "Native hit testing targets search after the timer view is retained (\(String(describing: hit.map { type(of: $0) })))")
            }
            expect(descendants(NSGlassEffectView.self, in: host).first === initialGlass,
                   "Mode switches retain the same glass backdrop")
        }
        print("All production Caffeine mode-switch, search, ruler and glass checks passed.")
    }

    @MainActor static func clickButton(_ label: String, in host: NSView, panel: NSPanel) async {
        // Production mode selector: 38pt header, 4pt top inset, 31pt capsule.
        let point = host.convert(NSPoint(x: host.bounds.midX + (label == "Timer" ? -35 : 35), y: 57.5), to: nil)
        await click(point, in: panel)
    }
    @MainActor static func click(_ point: NSPoint, in panel: NSPanel, drag: CGFloat = 0) async {
        let events: [(NSEvent.EventType, CGFloat)] = drag == 0 ? [(.leftMouseDown, 0), (.leftMouseUp, 0)] :
            [(.leftMouseDown, 0), (.leftMouseDragged, drag), (.leftMouseUp, drag)]
        for (type, offset) in events {
            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x + offset, y: point.y),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!, atStart: false)
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        while let event = NSApp.nextEvent(matching: mask, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        await settle()
    }
    @MainActor static func settle() async { try? await Task.sleep(for: .milliseconds(350)) }
    @MainActor static func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }
    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        FileHandle.standardOutput.write(Data("PASS: \(message)\n".utf8))
    }
}
