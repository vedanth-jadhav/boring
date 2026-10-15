import SwiftUI

struct RulerInputSurface: NSViewRepresentable {
    let input: RulerMouseDrag
    let tickSpacing: CGFloat
    let onChange: (Int) -> Void
    let onEnd: (Int) -> Void

    func makeNSView(context: Context) -> RulerMouseDrag { input }

    func updateNSView(_ view: RulerMouseDrag, context: Context) {
        view.tickSpacing = tickSpacing
        view.onChange = onChange
        view.onEnd = onEnd
    }

    static func dismantleNSView(_ view: RulerMouseDrag, coordinator: ()) {
        view.cancelDrag()
        view.onChange = { _ in }
        view.onEnd = { _ in }
    }
}
