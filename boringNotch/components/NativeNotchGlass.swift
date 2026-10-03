import AppKit
import SwiftUI

/// A persistent native backdrop, with no nested hosting view or synthetic rim.
/// AppKit owns the desktop sampling, refraction, and edge illumination.
@available(macOS 27.0, *)
struct NativeNotchGlass: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        glass.style = .clear
        glass.tintColor = nil
        glass.cornerRadius = cornerRadius
        // Transport buttons provide their own feedback. Treating the entire
        // platter as a button makes its material pulse with every interaction.
        glass.effectIsInteractive = false
        glass.contentView = NSView()
        return glass
    }

    func updateNSView(_ glass: NSGlassEffectView, context: Context) {
        if glass.cornerRadius != cornerRadius {
            glass.cornerRadius = cornerRadius
        }
    }
}
