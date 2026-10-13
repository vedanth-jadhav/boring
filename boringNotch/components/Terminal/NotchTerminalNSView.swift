import AppKit
import MetalKit
import QuartzCore
import SwiftTerm

final class NotchTerminalNSView: LocalProcessTerminalView {
    private var started = false
    private weak var inputPanel: BoringNotchSkyLightWindow?
    var tmuxPath: String?
    var exitHandler: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }




    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // The GPU canvas only paints; the terminal owns selection and keyboard focus.
        return hit is MTKView ? self : hit
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityValue() -> Any? {
        let terminal = getTerminal()
        return (0..<terminal.rows).compactMap { row in
            terminal.getLine(row: row)?.translateToString(trimRight: true,
                skipNullCellsFollowingWide: true, characterProvider: terminal.getCharacter)
        }.joined(separator: "\n")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusRingType = .none
        guard window != nil, !started, let tmuxPath else { return }
        started = true
        do { try setUseMetal(true) }
        catch { Log.general.debug("Terminal uses CoreGraphics: \(error.localizedDescription)") }
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        startProcess(executable: tmuxPath, args: ["-L", TerminalSessionSupport.socketName,
                     "attach-session", "-t", TerminalSessionSupport.sessionName],
                     environment: environment.map { "\($0.key)=\($0.value)" })
    }

    override func mouseDown(with event: NSEvent) {
        if let panel = window as? BoringNotchSkyLightWindow {
            inputPanel = panel
            panel.keyboardFocus.acquire(self, in: panel)
        }
        super.mouseDown(with: event)
    }

    func releaseKeyboard() {
        guard let panel = (window as? BoringNotchSkyLightWindow) ?? inputPanel else { return }
        panel.keyboardFocus.release(self, in: panel)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { releaseKeyboard() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        let opacity = backgroundOpacity
        // Shell color escapes may change RGB, but the app owns transparency.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        super.dataReceived(slice: slice)
        if backgroundOpacity != opacity { backgroundOpacity = opacity }
    }

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        super.processTerminated(source, exitCode: exitCode)
        exitHandler?()
    }

    // Commands may advertise OSC 8 links; only launch web links from this surface.
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}
