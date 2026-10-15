import AppKit

/// The notch stays nonactivating until the user clicks its search field.
final class CaffeineSearchTextField: NSSearchField {
    private weak var inputPanel: BoringNotchSkyLightWindow?
    private var releasingKeyboard = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // AppKit's internal renderer must not bypass the initial keyboard handoff.
        if let editor = currentEditor(), window?.firstResponder === editor, window?.isKeyWindow == true {
            return hit
        }
        return self
    }

    func focusForTyping() {
        if let panel = window as? BoringNotchSkyLightWindow {
            inputPanel = panel
            panel.keyboardFocus.acquire(self, in: panel)
        }
        keepEditorTransparent()
    }

    override func mouseDown(with event: NSEvent) {
        focusForTyping()
        super.mouseDown(with: event)
        keepEditorTransparent()
    }

    func keepEditorTransparent() {
        guard let editor = currentEditor() as? NSTextView else { return }
        if editor.drawsBackground { editor.drawsBackground = false }
        if editor.backgroundColor != .clear { editor.backgroundColor = .clear }
        if editor.insertionPointColor != .white { editor.insertionPointColor = .white }
        if editor.textColor != .white { editor.textColor = .white }
        if editor.focusRingType != .none { editor.focusRingType = .none }
    }

    func releaseKeyboard() {
        guard !releasingKeyboard, let panel = (window as? BoringNotchSkyLightWindow) ?? inputPanel else { return }
        releasingKeyboard = true
        defer { releasingKeyboard = false }
        panel.keyboardFocus.release(self, in: panel)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { releaseKeyboard() }
        super.viewWillMove(toWindow: newWindow)
    }
}
