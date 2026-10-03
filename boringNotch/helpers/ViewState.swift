import SwiftUI

/// Explicitly selects Apple's public property wrapper, preserving this fork's
/// existing state semantics. SDK 27 also exports a macro named State; the
/// standalone CLT 27 package does not contain its SwiftUIMacros plugin.
typealias ViewState<Value> = SwiftUI.State<Value>
