import AppKit
import SwiftUI

struct CaffeineSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CaffeineSearchTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        // Match the visible row instead of leaving padding outside the native hit area.
        return CGSize(width: width, height: height)
    }

    func makeNSView(context: Context) -> CaffeineSearchTextField {
        let field = CaffeineSearchTextField()
        field.isBordered = false
        field.isBezeled = true
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.appearance = NSAppearance(named: .darkAqua)
        field.focusRingType = .none
        field.controlSize = .small
        let font = NSFont.systemFont(ofSize: 11)
        field.font = font
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(string: "Find an app", attributes: [
            .font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.55)
        ])
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.sendsSearchStringImmediately = true
        field.setAccessibilityLabel("Find an app")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: CaffeineSearchTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }
    static func dismantleNSView(_ field: CaffeineSearchTextField, coordinator: Coordinator) {
        field.delegate = nil
        field.target = nil
        field.action = nil
        // Ending editing also happens during a button click; release only on teardown.
        field.releaseKeyboard()
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidBeginEditing(_ notification: Notification) {
            (notification.object as? CaffeineSearchTextField)?.keepEditorTransparent()
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            searchChanged(field)
        }
        @objc func searchChanged(_ field: NSSearchField) {
            if text.wrappedValue != field.stringValue { text.wrappedValue = field.stringValue }
        }
    }
}
