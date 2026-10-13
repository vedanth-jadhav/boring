import AppKit
import SwiftUI

struct CaffeineSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> CaffeineSearchTextField {
        let field = CaffeineSearchTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 11)
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(string: "Find an app", attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.55)])
        field.delegate = context.coordinator
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
        // Ending editing also happens during a button click; release only on teardown.
        field.releaseKeyboard()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidBeginEditing(_ notification: Notification) {
            (notification.object as? CaffeineSearchTextField)?.keepEditorTransparent()
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
