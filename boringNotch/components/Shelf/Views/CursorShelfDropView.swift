import AppKit
import SwiftUI

/// AppKit owns the drop surface; SwiftUI only draws its glass controls.
/// NSHostingView manages its own drag registrations, so it must not be the
/// destination for a drag that begins before this window exists.
@MainActor
final class CursorShelfDropView: NSView {
    weak var controller: CursorShelfController?
    private let hostingView: NSHostingView<CursorShelfView>

    init(rootView: CursorShelfView) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: CGRect(x: 0, y: 0, width: 420, height: 420))
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(rootView:)") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Log.shelf.debug("Cursor native drag entered")
        return update(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.clearHover() }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Log.shelf.debug("Cursor native prepare")
        _ = update(sender)
        return controller?.model.selected != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Log.shelf.debug("Cursor native perform")
        return controller?.accept(sender.draggingPasteboard) ?? false
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        Log.shelf.debug("Cursor native position \(point.x, privacy: .public), \(point.y, privacy: .public), flipped \(self.isFlipped, privacy: .public)")
        controller?.hover(CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y))
        return controller?.model.selected == nil ? [] : .copy
    }
}
