import AppKit
import SwiftUI

@MainActor
final class ShelfToolOptionsController: NSObject, NSWindowDelegate {
    static let shared = ShelfToolOptionsController()
    private var panel: NSPanel?

    func show(_ tool: ShelfTool, urls: [URL]) {
        close()
        SharingStateManager.shared.beginInteraction()
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = tool.title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.level = .floating
        let host = NSHostingView(rootView: ShelfToolOptionsView(tool: tool, urls: urls) { [weak self] in self?.close() })
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.center()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
        SharingStateManager.shared.endInteraction()
    }

    func windowWillClose(_ notification: Notification) { close() }
}
