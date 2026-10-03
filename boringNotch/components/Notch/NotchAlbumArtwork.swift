import SwiftUI

/// A single image survives the layout change instead of matching two images
/// inside disappearing, blurred, or clipped content trees.
struct NotchAlbumArtwork: View {
    @ObservedObject private var music = MusicManager.shared
    let rect: CGRect
    let expanded: Bool
    let cornerRadius: CGFloat
    let visible: Bool

    var body: some View {
        Image(nsImage: music.albumArt)
            .interpolation(.high)
            .resizable()
            .scaledToFit()
            .overlay {
                Color.black.opacity(expanded && !music.isPlaying ? 0.8 : 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .frame(width: max(0, rect.width), height: max(0, rect.height))
            .scaleEffect(expanded && !music.isPlaying ? 0.85 : 1)
            .position(x: rect.midX, y: rect.midY)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
