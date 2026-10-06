import Defaults
import SwiftUI

/// Artwork, labels and bars observe media independently of the notch shell.
struct NotchMusicActivityView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var musicManager = MusicManager.shared
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Default(.coloredSpectrogram) private var coloredSpectrogram
    @Default(.sneakPeekStyles) private var sneakPeekStyles
    let height: CGFloat
    let cornerScale: CGFloat?
    let centerWidth: CGFloat
    let closedWidth: CGFloat
    let gesture: CGFloat
    let albumArtNamespace: Namespace.ID
    private let inlineMusicPeekLabelWidth: CGFloat = 110

    var body: some View {
        HStack(spacing: 0) {
            // Closed-mode album art: scale padding and corner radius according to cornerScale
            let baseArtSize = height - 12
            let scaledArtSize: CGFloat = {
                if let scale = cornerScale {
                    return height - 12 * scale
                }
                return baseArtSize
            }()
            // The art's top/bottom gap to the pill; the leading offset below
            // trims the row's edge slack down to this same inset.
            let artVerticalInset = (height - scaledArtSize) / 2

            Color.clear
            .frame(width: scaledArtSize, height: scaledArtSize)
            .offset(x: artVerticalInset - liveActivityEdgeMargin)
            .anchorPreference(key: AlbumArtworkAnchorKey.self, value: .bounds) {
                [.closed: $0]
            }

            Rectangle()
                .fill(.black)
                .overlay(
                    // .center, not .top: the album art beside this is
                    // vertically centered, so top-aligned labels sat visibly
                    // high against it.
                    HStack(alignment: .center) {
                        if coordinator.expandingView.show
                            && coordinator.expandingView.type == .music {
                            SmoothTrackText(
                                text: musicManager.songTitle, font: .body,
                                color: coloredSpectrogram
                                    ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                width: inlineMusicPeekLabelWidth,
                                height: NSFont.preferredFont(forTextStyle: .body).pointSize * 1.3,
                                delayDuration: 0.4
                            )
                            .opacity(
                                (coordinator.expandingView.show
                                    && sneakPeekStyles == .inline)
                                    ? 1 : 0
                            )
                            Spacer(minLength: closedWidth)
                            // Song Artist
                            ZStack(alignment: .trailing) {
                                Text(musicManager.artistName)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .id(musicManager.artistName)
                                    .transition(.opacity)
                            }
                                .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.5), value: musicManager.artistName)
                                .frame(width: inlineMusicPeekLabelWidth, alignment: .trailing)
                                .foregroundStyle(
                                    coloredSpectrogram
                                        ? Color(nsColor: musicManager.avgColor)
                                        : Color.gray
                                )
                                .opacity(
                                    (coordinator.expandingView.show
                                        && coordinator.expandingView.type == .music
                                        && sneakPeekStyles == .inline)
                                        ? 1 : 0
                                )
                        }
                    }
                    .padding(.horizontal, 8)
                )
                .frame(width: centerWidth)

            MusicVisualizer(
                isPlaying: musicManager.isPlaying,
                tintColor: coloredSpectrogram
                    ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.5)
                    : Color.gray
            )
            .frame(width: 18, height: 12)
            .frame(
                width: max(
                    0,
                    height - 12
                        + gesture / 2
                ),
                height: max(
                    0,
                    height - 12
                ),
                alignment: .center
            )
        }
        .frame(
            height: height,
            alignment: .center
        )
    }
}
