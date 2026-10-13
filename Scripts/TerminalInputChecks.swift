import AppKit
import OSLog
import SwiftTerm
import Defaults

// An unshown host keeps these component tests out of the user's desktop.
final class BoringNotchSkyLightWindow: NSPanel {
    let keyboardFocus = NotchKeyboardFocus()
    var wantsKeyForTextInput = false
    private(set) var keyRequests = 0
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
}

enum Log {
    static let general = Logger(subsystem: "TerminalInputChecks", category: "terminal")
}

extension Defaults.Keys {
    static let terminalEnabled = Key<Bool>("terminalEnabled", default: true)
    static let terminalApplication = Key<String>("terminalApplication", default: "com.apple.Terminal")
}

@main struct TerminalInputChecks {
    @MainActor static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "TerminalInputChecks", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let viewStart = Date()
        let panel = BoringNotchSkyLightWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 200),
                                            styleMask: [.borderless, .nonactivatingPanel],
                                            backing: .buffered, defer: false)
        let terminal = NotchTerminalNSView(frame: NSRect(x: 0, y: 0, width: 560, height: 200))
        panel.contentView = terminal
        terminal.nativeBackgroundColor = .black
        terminal.backgroundOpacity = 0
        defer { terminal.terminate(); panel.contentView = nil }

        let metalStart = Date()
        try terminal.setUseMetal(true)
        let metalMilliseconds = Date().timeIntervalSince(metalStart) * 1000
        let viewMilliseconds = Date().timeIntervalSince(viewStart) * 1000
        try expect(terminal.isUsingMetalRenderer, "Exercise the real Metal rendering path")
        try expect(terminal.focusRingType == .none, "No native focus decoration may cover the glass terminal")
        let hit = terminal.hitTest(NSPoint(x: 140, y: 80))
        try expect(hit === terminal, "The Metal canvas must route text-area clicks to the terminal")
        try expect(terminal.acceptsFirstMouse(for: nil), "The first click must work while another app is active")
        try expect(terminal.needsPanelToBecomeKey, "Terminal input must request a key panel")
        if let scroller = terminal.subviews.compactMap({ $0 as? NSScroller }).first {
            scroller.isEnabled = true
            scroller.isHidden = false
            scroller.frame = NSRect(x: 544, y: 0, width: 16, height: 200)
            try expect(terminal.hitTest(NSPoint(x: scroller.frame.midX, y: scroller.frame.midY)) === scroller,
                       "Keep the real scrollbar interactive")
        }
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 140, y: 80),
                                      modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                                      context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let originalFrame = terminal.frame
        hit?.mouseDown(with: click)
        try expect(panel.wantsKeyForTextInput, "Clicking must enable the notch's keyboard focus")
        try expect(panel.firstResponder === terminal, "Typing must reach the terminal, not its Metal child")
        try expect(panel.keyRequests == 1, "The first click must request focus once, without duplicate redraws")
        hit?.mouseDown(with: click)
        try expect(panel.firstResponder === terminal, "Repeated input requests preserve the terminal responder")
        try expect(terminal.frame == originalFrame && terminal.backgroundOpacity == 0,
                   "First-click focus must preserve terminal geometry and translucency")
        let otherPanel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        otherPanel.makeKey()
        hit?.mouseDown(with: click)
        try expect(panel.firstResponder === terminal,
                   "Returning from another app must restore typing with one focus request")

        let appearance = UserDefaults(suiteName: "local.vedanth.boringnotch.octave")!
        let glassBefore = appearance.object(forKey: "reduceGlass") as? Bool
        let speedBefore = appearance.object(forKey: "animationSpeedMultiplier") as? Double
        let animationsBefore = appearance.object(forKey: "enableOpeningAnimation") as? Bool
        for opacity: CGFloat in [0, 0.35, 1] {
            terminal.backgroundOpacity = opacity
            for output in ["\u{1b}]11;#101112\u{7}", "\u{1b}[0mPrompt ", "\u{1b}]111\u{7}"] {
                terminal.dataReceived(slice: Array(output.utf8)[...])
                try expect(abs(terminal.backgroundOpacity - opacity) < 0.001,
                           "Shell color updates must preserve the configured terminal opacity")
                try expect(terminal.frame == originalFrame, "Output must not resize the terminal")
            }
        }
        terminal.backgroundOpacity = 0

        terminal.startProcess(executable: "/bin/cat")
        for (key, code) in [("x", UInt16(7)), ("y", UInt16(16)), ("z", UInt16(6)), ("\r", UInt16(36))] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                        timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                        characters: key, charactersIgnoringModifiers: key,
                                        isARepeat: false, keyCode: code)!
            panel.sendEvent(event)
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if (terminal.accessibilityValue() as? String)?.contains("xyz") == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try expect((terminal.accessibilityValue() as? String)?.contains("xyz") == true,
                   "Real key events must reach the PTY and render its output")
        try expect(terminal.backgroundOpacity == 0 && terminal.frame == originalFrame,
                   "Typing and PTY redraws preserve transparency and geometry")
        try expect((appearance.object(forKey: "reduceGlass") as? Bool) == glassBefore
                   && (appearance.object(forKey: "animationSpeedMultiplier") as? Double) == speedBefore
                   && (appearance.object(forKey: "enableOpeningAnimation") as? Bool) == animationsBefore,
                   "Typing never changes glass or animation preferences")
        let search = CaffeineSearchTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        terminal.addSubview(search)
        search.focusForTyping()
        let editor = search.currentEditor()
        terminal.releaseKeyboard()
        try expect(editor != nil && panel.firstResponder === editor && panel.wantsKeyForTextInput,
                   "Outgoing terminal preserves the incoming search responder")
        hit?.mouseDown(with: click)
        search.releaseKeyboard()
        try expect(panel.firstResponder === terminal && panel.wantsKeyForTextInput,
                   "Outgoing search preserves the incoming terminal responder")
        terminal.releaseKeyboard()
        try expect(!panel.wantsKeyForTextInput, "Owned terminal teardown releases input")
        try await checkStartup()
        print("Terminal startup, Metal routing, stable first-click focus, scrollbar, and PTY typing checks passed.")
        print("View preparation: \(Int(viewMilliseconds)) ms; Metal setup: \(Int(metalMilliseconds)) ms.")
    }

    @MainActor static func checkStartup() async throws {
        guard let tmux = TerminalSessionBackend.tmuxPath else { return }
        let socket = "boring-input-check-" + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(socket)
        let backend = TerminalSessionBackend(tmux: tmux, socketName: socket, sessionName: "check",
                                            configurationURL: directory.appendingPathComponent("tmux.conf"))
        let manager = NotchTerminalManager(backend: backend)
        defer {
            manager.setEnabled(false)
            let cleanup = Process()
            cleanup.executableURL = URL(fileURLWithPath: tmux)
            cleanup.arguments = ["-L", socket, "kill-server"]
            try? cleanup.run()
            cleanup.waitUntilExit()
            try? FileManager.default.removeItem(at: directory)
        }
        let first = Date()
        await manager.start()
        let firstMilliseconds = Date().timeIntervalSince(first) * 1000
        try expect(manager.isRunning && !manager.isStarting && manager.error == nil,
                   "The shell must be available as soon as session startup completes")
        let warm = Date()
        await manager.start()
        let warmMilliseconds = Date().timeIntervalSince(warm) * 1000
        try expect(warmMilliseconds < 50, "Reopening a running terminal must avoid subprocess and socket scans")
        await manager.start(force: true)
        try expect(manager.isRunning && manager.error == nil, "Explicit reconnect must still validate the session")
        print("Session start: \(Int(firstMilliseconds)) ms; warm reopen: \(Int(warmMilliseconds)) ms.")
    }
}
