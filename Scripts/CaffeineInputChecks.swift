import AppKit
import SwiftUI

// These fixtures are never shown and cannot activate or alter the user's app.
final class BoringNotchSkyLightWindow: NSPanel {
    let keyboardFocus = NotchKeyboardFocus()
    var wantsKeyForTextInput = false
    private(set) var keyRequests = 0
    private(set) var resignRequests = 0
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted, let view = responder as? NSView,
           view is NSTextField || view is NSTextInputClient {
            let input = (view as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSView : nil } ?? view
            keyboardFocus.becameFirstResponder(input, in: self)
        }
        return accepted
    }

    override var canBecomeKey: Bool { wantsKeyForTextInput }
    override func makeKey() { keyRequests += 1; super.makeKey() }
    override func resignKey() { resignRequests += 1; super.resignKey() }
}

private final class SettingsShortcutTrap: NSButton {
    var receivedKeys = 0
    var clicks = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        target = self
        action = #selector(clicked)
    }
    required init?(coder: NSCoder) { fatalError("Unavailable in this fixture") }
    @objc private func clicked() { clicks += 1 }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { receivedKeys += 1 }
}

@main struct CaffeineInputChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let panel = BoringNotchSkyLightWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let container = NSView(frame: panel.contentLayoutRect)
        panel.contentView = container
        defer { panel.contentView = nil }
        let field = CaffeineSearchTextField(frame: NSRect(x: 20, y: 40, width: 300, height: 22))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        container.addSubview(field)
        let trap = SettingsShortcutTrap(frame: .zero)
        container.addSubview(trap)
        panel.makeFirstResponder(trap)
        var query = ""
        let coordinator = CaffeineSearchField.Coordinator(text: Binding(get: { query }, set: { query = $0 }))
        field.delegate = coordinator
        let preferences = UserDefaults(suiteName: "local.vedanth.boringnotch.octave")!
        let glassBefore = preferences.object(forKey: "reduceGlass") as? Bool
        let animationSpeedBefore = preferences.object(forKey: "animationSpeedMultiplier") as? Double
        let animationsBefore = preferences.object(forKey: "enableOpeningAnimation") as? Bool
        expect(field.acceptsFirstMouse(for: nil) && field.needsPanelToBecomeKey, "Search accepts the first click in a nonactivating notch")
        field.focusForTyping()
        expect(panel.wantsKeyForTextInput, "Search requests keyboard input")
        expect(panel.keyRequests == 1, "The first search click only requests focus once")
        guard let editor = field.currentEditor() as? NSTextView else {
            throw NSError(domain: "CaffeineInputChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Search did not obtain a text editor"])
        }
        expect(panel.firstResponder === editor, "Typing goes to search instead of another settings control")
        expect(!editor.drawsBackground && editor.backgroundColor == .clear, "Search editor preserves the glass surface")
        field.focusForTyping()
        field.keepEditorTransparent()
        expect(panel.firstResponder === editor,
               "Repeated search requests preserve the field editor")
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        for (key, code) in [("B", UInt16(11)), ("r", 15), ("a", 0), ("v", 9), ("e", 14), (" ", 49),
                            ("B", 11), ("r", 15), ("o", 31), ("w", 13), ("s", 1), ("e", 14), ("r", 15)] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: key == "B" ? .shift : [], timestamp: 0, windowNumber: panel.windowNumber,
                context: nil, characters: key, charactersIgnoringModifiers: key.lowercased(),
                isARepeat: false, keyCode: code)!
            panel.sendEvent(event)
        }
        expect(editor.string == "Brave Browser", "An app name with a space is typed into search")
        expect(query == "Brave Browser", "Typing updates the app filter binding")
        expect(trap.receivedKeys == 0, "Search keys never reach a settings control")
        expect((preferences.object(forKey: "reduceGlass") as? Bool) == glassBefore, "Searching leaves the saved glass preference unchanged")
        panel.makeFirstResponder(trap)
        expect(panel.firstResponder === trap, "Leaving search preserves the newly focused button")
        expect(panel.wantsKeyForTextInput && panel.resignRequests == 0,
               "Ending search editing must not deactivate a button click")
        trap.performClick(nil)
        expect(trap.clicks == 1, "The control after a search receives its action on the first click")
        field.releaseKeyboard()
        expect(panel.firstResponder === trap, "Search teardown must not clear another control's responder")
        expect(panel.wantsKeyForTextInput, "Search teardown preserves another control's keyboard ownership")
        field.focusForTyping()
        let nextField = CaffeineSearchTextField(frame: NSRect(x: 20, y: 10, width: 300, height: 22))
        container.addSubview(nextField)
        nextField.focusForTyping()
        let nextEditor = nextField.currentEditor()
        field.releaseKeyboard()
        expect(nextEditor != nil && panel.firstResponder === nextEditor && panel.wantsKeyForTextInput,
               "Disposing the old search must not steal focus from a new text input")
        nextField.releaseKeyboard()
        expect(!panel.wantsKeyForTextInput, "The last text input releases the panel on teardown")
        expect((preferences.object(forKey: "animationSpeedMultiplier") as? Double) == animationSpeedBefore
               && (preferences.object(forKey: "enableOpeningAnimation") as? Bool) == animationsBefore,
               "Search and subsequent clicks leave the animation settings unchanged")
        print("Caffeine search focus, typing, filter binding, transparent editor, and appearance preference checks passed.")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        FileHandle.standardOutput.write(Data("PASS: \(message)\n".utf8))
    }
}
