import AppKit
import SwiftUI

@MainActor
final class ShelfToolFeedback {
    static let shared = ShelfToolFeedback()
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var tool: ShelfTool = .save

    func dismiss() {
        dismissTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }

    func begin(_ tool: ShelfTool) {
        self.tool = tool
        dismissTask?.cancel()
        let panel = self.panel ?? NSPanel(contentRect: CGRect(x: 0, y: 0, width: 330, height: 64), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            let frame = screen.visibleFrame.insetBy(dx: 20, dy: 20)
            panel.setFrameOrigin(CGPoint(x: min(max(mouse.x - 165, frame.minX), frame.maxX - 330), y: min(max(mouse.y - 100, frame.minY), frame.maxY - 64)))
        }
        update("\(tool.title)…", working: true)
        panel.orderFrontRegardless()
    }

    func update(_ text: String, working: Bool) {
        guard let panel else { return }
        panel.contentView = NSHostingView(rootView:
            HStack(spacing: 12) {
                if working { ProgressView().controlSize(.small) }
                else { Image(systemName: tool.symbol).foregroundStyle(tool.tint).font(.title3) }
                Text(text).font(.system(size: 12, weight: .medium)).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18).frame(width: 322, height: 56)
            .modifier(ShelfGlass(radius: 18)).padding(4).preferredColorScheme(.dark)
        )
        dismissTask?.cancel()
        if !working {
            dismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                self?.panel?.orderOut(nil)
                self?.panel = nil
            }
        }
    }
}
