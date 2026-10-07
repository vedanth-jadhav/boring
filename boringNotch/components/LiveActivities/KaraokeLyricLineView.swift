import SwiftUI

struct KaraokeLyricLineView: View {
    let row: LyricVocalFrame.Row
    private var words: [LyricLine.Word] { row.words }
    let elapsed: Double
    let sampleDate: Date
    let playbackRate: Double
    let isPlaying: Bool
    let romanize: Bool
    let width: CGFloat
    let pointSize: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout = LyricTextLayout.cached(words: words, rowID: row.id, romanize: romanize, pointSize: pointSize, width: width)
        TimelineView(.animation(minimumInterval: row.animationInterval(rate: playbackRate),
                                paused: !isPlaying || playbackRate <= 0 || reduceMotion || !row.isActive(at: elapsed))) { timeline in
            let position = LyricPlaybackClock.position(anchorPosition: elapsed, anchorDate: sampleDate,
                at: max(timeline.date, Date.now), rate: playbackRate, playing: isPlaying,
                duration: .greatestFiniteMagnitude)
            content(layout: layout, at: position)
        }
        .transaction { $0.animation = nil }
        .frame(width: max(0, width), height: pointSize * 1.65, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(layout.accessibilityText)
    }

    private func content(layout: LyricTextLayout, at position: Double) -> some View {
        let anchor = row.anchor(at: position)
        let visibleRange = layout.pageForWord.indices.contains(anchor) ? layout.pageForWord[anchor] : words.indices

        return Group {
                if row.highlightsWords {
                    LyricCanvasView(layout: layout, words: words, visibleRange: visibleRange, position: position,
                                    exactTiming: row.hasExactTiming, reduceMotion: reduceMotion, pointSize: pointSize)
                } else {
                    // LRC can identify the sung line, not individual words.
                    // Illuminate that whole phrase on its actual line window.
                    HighlightedLyricWord(text: layout.text[visibleRange].joined(separator: " "), pointSize: pointSize,
                                         word: .init(text: row.text, start: row.start, end: row.end),
                                         elapsed: position, hasExactTiming: false, reduceMotion: reduceMotion)
                        .lineLimit(1)
                        .minimumScaleFactor(0.1)
                        .frame(width: max(0, width), alignment: .leading)
                }
        }
        // Show the new page fully at its timestamp. Animation remains within
        // active glyphs, rather than delaying the visibility of their text.
        .transaction { $0.animation = nil }
    }
}
