import SwiftUI
import SwiftTerm
import Defaults

struct EmbeddedTerminalView: NSViewRepresentable {
    let tmuxPath: String
    let onExit: () -> Void
    @Default(.reduceGlass) private var reduceGlass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var backgroundOpacity: CGFloat {
        reduceGlass || reduceTransparency || contrast == .increased ? 1 : 0
    }

    func makeNSView(context: Context) -> NotchTerminalNSView {
        let options = TerminalOptions(termName: "xterm-256color", cursorStyle: .steadyBar,
                                      scrollback: 2000, kittyImageCacheLimitBytes: 16 * 1024 * 1024,
                                      regionalIndicatorWidth: .narrow)
        let view = NotchTerminalNSView(frame: CGRect(x: 0, y: 0, width: 560, height: 200),
                                      font: .monospacedSystemFont(ofSize: 12, weight: .regular), options: options)
        view.nativeBackgroundColor = .black
        view.backgroundOpacity = backgroundOpacity
        view.nativeForegroundColor = NSColor(white: 0.93, alpha: 1)
        view.tmuxPath = tmuxPath
        view.exitHandler = onExit
        view.setAccessibilityLabel("Notch terminal")
        return view
    }

    func updateNSView(_ nsView: NotchTerminalNSView, context: Context) {
        if nsView.backgroundOpacity != backgroundOpacity { nsView.backgroundOpacity = backgroundOpacity }
    }

    static func dismantleNSView(_ nsView: NotchTerminalNSView, coordinator: ()) {
        nsView.exitHandler = nil
        nsView.releaseKeyboard()
        // This stops only the tmux display client. Shells and servers stay in the session.
        nsView.terminate()
    }
}
