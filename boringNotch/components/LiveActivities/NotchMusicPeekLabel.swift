import Defaults
import SwiftUI

struct NotchMusicPeekLabel: View {
    @ObservedObject private var music = MusicManager.shared
    @Default(.playerColorTinting) private var playerColorTinting
    let width: CGFloat

    var body: some View {
        SmoothTrackText(text: music.songTitle + " - " + music.artistName, font: .body,
                        color: playerColorTinting ? Color(nsColor: music.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray,
                        width: width, height: NSFont.preferredFont(forTextStyle: .body).pointSize * 1.3, delayDuration: 1)
    }
}
