import Defaults
import SwiftUI

/// Content is prepared per row; only exact word timing needs animation ticks.
struct KaraokeLyricsView: View {
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var lyrics = LyricsService.shared
    @Default(.romanizeLyrics) private var romanizeLyrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let width: CGFloat
    var pointSize: CGFloat = NSFont.preferredFont(forTextStyle: .subheadline).pointSize

    var onHeightChange: ((CGFloat) -> Void)? = nil

    var body: some View {
        Group {
            if lyrics.hasWordTimings {
                TimelineView(.animation(minimumInterval: reduceMotion ? 0.1 : 1.0 / 30,
                                        paused: !music.isPlaying || music.playbackRate <= 0)) { timeline in
                    lyricContent(at: timeline.date)
                }
            } else {
                TimelineView(.explicit(lyrics.displayDates(anchorPosition: music.elapsedTime,
                    anchorDate: music.timestampDate, rate: music.playbackRate, playing: music.isPlaying))) { timeline in
                    lyricContent(at: timeline.date)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func lyricContent(at date: Date) -> some View {
        let elapsed = music.estimatedPlaybackPosition(at: date)
        let frame = lyrics.vocalFrame(at: elapsed, duration: music.songDuration)
        let rowIDs = frame.rows.map(\.id)
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .leading) {
                if let row = frame.rows.first {
                    lyricRow(row, elapsed: elapsed, width: width, size: pointSize)
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
                lyricRow(row, elapsed: elapsed, width: max(0, width - 5), size: pointSize * 0.88)
                    .padding(.leading, 5)
                    .id(row.id)
                    .transition(.opacity)
                    .frame(width: max(0, width), height: pointSize * 1.45, alignment: .leading)
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.08 : 0.18), value: rowIDs)
        .onAppear { onHeightChange?(pointSize * (frame.rows.count > 1 ? 3.1 : 1.65)) }
        .onChange(of: frame.rows.count) { _, count in
            onHeightChange?(pointSize * (count > 1 ? 3.1 : 1.65))
        }
    }

    @ViewBuilder
    private func lyricRow(_ row: LyricVocalFrame.Row, elapsed: Double, width: CGFloat, size: CGFloat) -> some View {
        if row.hasExactTiming {
            KaraokeLyricLineView(row: row, elapsed: elapsed, romanize: romanizeLyrics,
                                 width: width, pointSize: size, isPlaying: music.isPlaying)
        } else {
            // No invented word highlight for LRC. Keep long lines readable
            // with whole-word pages, changed only at their prepared boundaries.
            let layout = LyricTextLayout.cached(words: row.words, rowID: row.id, romanize: romanizeLyrics,
                                                pointSize: size, width: width)
            let anchor = row.anchor(at: elapsed)
            let range = layout.pageForWord.indices.contains(anchor) ? layout.pageForWord[anchor] : row.words.indices
            Text(layout.text[range].joined(separator: " "))
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .frame(width: max(0, width), height: size * 1.65, alignment: .leading)
                .accessibilityLabel(layout.accessibilityText)
        }
    }
}
