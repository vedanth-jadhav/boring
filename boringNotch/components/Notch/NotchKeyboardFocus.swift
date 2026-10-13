import AppKit

@MainActor
final class NotchKeyboardFocus {
    private weak var owner: NSView?
    private weak var returnWindow: NSWindow?
    private var acquiring = false
    private weak var releasingOwner: NSView?

    private func prepare(_ panel: BoringNotchSkyLightWindow) {
        if !panel.wantsKeyForTextInput {
            returnWindow = NSApp.keyWindow === panel ? nil : NSApp.keyWindow
            panel.wantsKeyForTextInput = true
        }
    }

    func acquire(_ view: NSView, in panel: BoringNotchSkyLightWindow) {
        guard !acquiring, releasingOwner !== view else { return }
        acquiring = true
        defer { acquiring = false }
        let previouslyEnabled = panel.wantsKeyForTextInput
        prepare(panel)
        let editor = (view as? NSTextField)?.currentEditor()
        if panel.firstResponder !== view && (editor == nil || panel.firstResponder !== editor) {
            guard panel.makeFirstResponder(view) else {
                panel.wantsKeyForTextInput = previouslyEnabled
                return
            }
        }
        owner = view
        if !panel.isKeyWindow { panel.makeKey() }
    }

    /// AppKit can assign focus through Tab or accessibility without a mouseDown.
    func becameFirstResponder(_ view: NSView, in panel: BoringNotchSkyLightWindow) {
        guard releasingOwner !== view else { return }
        prepare(panel)
        owner = view
        if !acquiring && !panel.isKeyWindow { panel.makeKey() }
    }

    func inputResponder(in panel: BoringNotchSkyLightWindow) -> NSResponder? {
        guard let owner, owner.window === panel else { return nil }
        if panel.firstResponder === owner { return owner }
        if let editor = (owner as? NSTextField)?.currentEditor(), panel.firstResponder === editor { return editor }
        return nil
    }

    func release(_ view: NSView, in panel: BoringNotchSkyLightWindow) {
        guard owner === view, inputResponder(in: panel) != nil else { return }
        releasingOwner = view
        defer { releasingOwner = nil }
        guard panel.makeFirstResponder(nil) else { return }
        // Ending editing can synchronously install a new responder.
        guard owner === view, panel.firstResponder == nil || panel.firstResponder === panel else { return }
        owner = nil
        panel.wantsKeyForTextInput = false
        guard panel.isKeyWindow else { return }
        if let returnWindow, returnWindow.isVisible, returnWindow.canBecomeKey {
            returnWindow.makeKey()
        } else {
            let wasVisible = panel.isVisible
            panel.orderOut(nil)
            if wasVisible { panel.orderFrontRegardless() }
        }
        returnWindow = nil
    }
}
