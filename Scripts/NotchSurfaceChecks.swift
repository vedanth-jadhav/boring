import AppKit
import Defaults
import SwiftUI

private let surfaceTestDefaults = UserDefaults(suiteName: "boring.notch-surface-checks")!
extension Defaults.Keys {
    static let normalizeGestureDirection = Key<Bool>("normalizeGestureDirection", default: false, suite: surfaceTestDefaults)
    static let reduceGlass = Key<Bool>("reduceGlass", default: false, suite: surfaceTestDefaults)
}

@MainActor private final class SurfaceState: ObservableObject {
    @Published var expanded = false
}

@MainActor private struct SurfaceFixture: View {
    @ObservedObject var state: SurfaceState
    var usesBrokenGestureWrapper = false
    var body: some View {
        LiquidGlassSurface(shape: NotchShape(topCornerRadius: state.expanded ? 19 : 6,
                                            bottomCornerRadius: state.expanded ? 32 : 14),
                           expanded: state.expanded, width: state.expanded ? 640 : 185,
                           height: state.expanded ? 190 : 32) {
            VStack(spacing: 0) {
                Color.clear.frame(height: 32)
                if state.expanded { Text("Controls").frame(maxWidth: .infinity, minHeight: 146) }
            }
        }
        .conditionalModifier(usesBrokenGestureWrapper && !state.expanded) {
            $0.gesture(TapGesture().onEnded {})
        }
        // Exercise the actual wrapper that used to be inserted/removed on open.
        .gesture(TapGesture().onEnded {}, including: state.expanded ? .subviews : .all)
        .panGesture(direction: .down, isEnabled: !state.expanded) { _, _ in }
        .panGesture(direction: .up, isEnabled: state.expanded) { _, _ in }
        .panGesture(direction: .left, isEnabled: !state.expanded) { _, _ in }
        .panGesture(direction: .right, isEnabled: !state.expanded) { _, _ in }
        .environment(\.appearsActive, true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

@main struct NotchSurfaceChecks {
    @MainActor static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
    @MainActor static func glasses(in view: NSView) -> [NSGlassEffectView] {
        (view as? NSGlassEffectView).map { [$0] } ?? view.subviews.flatMap { glasses(in: $0) }
    }
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        defer { surfaceTestDefaults.removePersistentDomain(forName: "boring.notch-surface-checks") }
        Defaults[.reduceGlass] = false
        let state = SurfaceState()
        let host = NSHostingView(rootView: SurfaceFixture(state: state))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 720, height: 320),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        pump(0.1)
        guard let glass = glasses(in: host).first else { fatalError("Native backdrop missing") }
        precondition(glasses(in: host).count == 1, "Exactly one backdrop must own the notch")
        precondition(abs(glass.bounds.width - 185) < 1 && abs(glass.bounds.height - 32) < 1, "Closed surface must have numeric bounds")
        var samples: [CGSize] = []
        for expanded in [true, false, true, false] {
            withAnimation(.linear(duration: 0.25)) { state.expanded = expanded }
            var cycle: [CGSize] = []
            for _ in 0..<18 {
                pump(1.0 / 60)
                let backdrops = glasses(in: host)
                precondition(backdrops.count == 1 && backdrops[0] === glass, "Opening/closing must resize the same backdrop rather than crossfade replacements")
                precondition(!glass.effectIsInteractive, "The entire panel must not pulse like a button")
                precondition(!glass.isHidden && glass.alphaValue == 1, "The backdrop must remain visible rather than fading out")
                precondition(glass.bounds.width.isFinite && glass.bounds.height.isFinite, "Animation bounds must stay finite")
                samples.append(glass.bounds.size)
                cycle.append(glass.bounds.size)
            }
            precondition(cycle.contains { $0.width > 190 && $0.width < 635 && $0.height > 34 && $0.height < 188 }, "Both size dimensions must pass through intermediate values rather than jump")
            for (previous, next) in zip(cycle, cycle.dropFirst()) {
                precondition(expanded ? next.width >= previous.width - 1 : next.width <= previous.width + 1, "Surface width must move continuously in the transition direction")
                precondition(expanded ? next.height >= previous.height - 1 : next.height <= previous.height + 1, "Surface height must move continuously in the transition direction")
            }
            precondition(abs(glass.bounds.width - (expanded ? 640 : 185)) < 1, "Surface width must reach its target")
            precondition(abs(glass.bounds.height - (expanded ? 190 : 32)) < 1, "Surface height must reach its target")
        }
        print("SAMPLES: \(samples.prefix(8).map { String(format: "%.1fx%.1f", $0.width, $0.height) }.joined(separator: ", "))")
        Defaults[.reduceGlass] = true
        pump(0.1)
        precondition(glasses(in: host).isEmpty, "Reduce Glass must keep its solid fallback")
        Defaults[.reduceGlass] = false
        host.rootView = SurfaceFixture(state: state, usesBrokenGestureWrapper: true)
        pump(0.1)
        guard let oldBackdrop = glasses(in: host).first else { fatalError("Baseline backdrop missing") }
        withAnimation(.linear(duration: 0.25)) { state.expanded = true }
        pump(0.07)
        let recreated = glasses(in: host)
        precondition(recreated.count != 1 || recreated.first !== oldBackdrop, "The regression fixture must reproduce the old conditional-wrapper replacement")
        print("PASS: old gesture wrapper reproduces backdrop replacement; fixed wrappers keep one backdrop through smooth opening/closing and preserve Reduce Glass")
    }
}
