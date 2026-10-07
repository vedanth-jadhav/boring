import Defaults
import SwiftUI

/// Rows update at source timestamps; only active glyphs animate independently.
struct KaraokeLyricsView: View {
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var lyrics = LyricsService.shared
    @Default(.romanizeLyrics) private var romanizeLyrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let width: CGFloat
    var pointSize: CGFloat = NSFont.preferredFont(forTextStyle: .subheadline).pointSize

    var onHeightChange: ((CGFloat) -> Void)? = nil

    var body: some View {
        TimelineView(.explicit(lyrics.displayDates(anchorPosition: music.elapsedTime,
            anchorDate: music.timestampDate, rate: music.playbackRate, playing: music.isPlaying,
            wordBoundaries: reduceMotion, singleRow: true))) { timeline in
            // A busy run loop may deliver a boundary late. Sample the actual
            // clock so the screen never replays a missed highlight.
            lyricContent(at: max(timeline.date, Date.now))
        }
        .frame(width: max(0, width), height: pointSize * 1.65, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { onHeightChange?(pointSize * 1.65) }
        .onChange(of: pointSize) { _, size in onHeightChange?(size * 1.65) }
    }

    private func lyricContent(at date: Date) -> some View {
        let elapsed = music.estimatedPlaybackPosition(at: date)
        return Group {
            if let row = lyrics.displayedRow(at: elapsed) {
                // Keep the same view and canvas across line/page handoffs.
                // Replacing their identities tears down the running clock.
                lyricRow(row, elapsed: elapsed, sampleDate: date, width: width, size: pointSize)
            } else if lyrics.timedLyrics.isEmpty {
                let plain = lyrics.currentLyrics.components(separatedBy: .newlines)
                    .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
                let text = lyrics.isFetchingLyrics ? "Loading lyrics…" : (plain.isEmpty ? "No lyrics found" : plain)
                TimedLyricText(romanizeLyrics ? LyricsRomanizer.romanize(text) : text,
                               font: .system(size: pointSize), color: .white.opacity(0.65), frameWidth: width)
            }
        }
        // A sung line must be readable at onset, including rapid track/seek
        // changes inherited from an animated parent container.
        .transaction { $0.animation = nil }
    }

    private func lyricRow(_ row: LyricVocalFrame.Row, elapsed: Double, sampleDate: Date, width: CGFloat, size: CGFloat) -> some View {
        KaraokeLyricLineView(row: row, elapsed: elapsed, sampleDate: sampleDate,
                             playbackRate: music.playbackRate, isPlaying: music.isPlaying, romanize: romanizeLyrics,
                             width: width, pointSize: size)
    }
}
