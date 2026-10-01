import Defaults
import SwiftUI

/// The media clock drives every word and vocal lane at the display's cadence.
struct KaraokeLyricsView: View {
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var lyrics = LyricsService.shared
    @Default(.romanizeLyrics) private var romanizeLyrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let width: CGFloat
    var pointSize: CGFloat = NSFont.preferredFont(forTextStyle: .subheadline).pointSize

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.1 : nil,
                                paused: !music.isPlaying || lyrics.timedLyrics.isEmpty)) { timeline in
            let elapsed = music.estimatedPlaybackPosition(at: timeline.date)
            let frame = LyricVocalFrame(entries: lyrics.displayedLines(at: elapsed, duration: music.songDuration), elapsed: elapsed)
            let rowIDs = frame.rows.map(\.id)
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .leading) {
                    if let row = frame.rows.first {
                        KaraokeLyricLineView(words: row.words, elapsed: elapsed, romanize: romanizeLyrics,
                                             width: width, pointSize: pointSize, isPlaying: music.isPlaying)
                            .id(row.id)
                            .transition(.opacity)
                    } else if lyrics.timedLyrics.isEmpty {
                        let plain = lyrics.currentLyrics.components(separatedBy: .newlines)
                            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
                        let text = lyrics.isFetchingLyrics ? "Loading lyrics…" : (plain.isEmpty ? "No lyrics found" : plain)
                        TimedLyricText(romanizeLyrics ? LyricsRomanizer.romanize(text) : text,
                                       font: .system(size: pointSize), color: .white.opacity(0.65), frameWidth: width)
                            .id(text)
                            .transition(.opacity)
                    }
                }
                .frame(width: max(0, width), height: pointSize * 1.65, alignment: .leading)

                if frame.rows.count > 1 {
                    let row = frame.rows[1]
                    KaraokeLyricLineView(words: row.words, elapsed: elapsed, romanize: romanizeLyrics,
                                         width: max(0, width - 5), pointSize: pointSize * 0.88, isPlaying: music.isPlaying)
                        .padding(.leading, 5)
                        .id(row.id)
                        .transition(.opacity)
                        .frame(width: max(0, width), height: pointSize * 1.45, alignment: .leading)
                }
            }
            .animation(.easeInOut(duration: reduceMotion ? 0.08 : 0.18), value: rowIDs)
        }
        // TimelineView must keep the height of its actual lyric content,
        // rather than absorb the space offered by the player GeometryReader.
        .fixedSize(horizontal: false, vertical: true)
    }
}
