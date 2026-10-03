import SwiftUI

/// Keep destinations separate: disappearing views can retain their preferences.
struct AlbumArtworkAnchorKey: PreferenceKey {
    enum Slot: Hashable {
        case open
        case closed
        case hidden
    }

    static var defaultValue: [Slot: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [Slot: Anchor<CGRect>], nextValue: () -> [Slot: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
