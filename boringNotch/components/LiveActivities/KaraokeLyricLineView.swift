import SwiftUI

struct KaraokeLyricLineView: View {
    let row: LyricVocalFrame.Row
    let previousRow: LyricVocalFrame.Row?
    let displayStart: Double
    let elapsed: Double
    let sampleDate: Date
    let playbackRate: Double
    let isPlaying: Bool
    let romanize: Bool
    let width: CGFloat
    let pointSize: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if row.hasExactTiming { timedWords }
            else {
                Text(romanize ? LyricsRomanizer.romanize(row.text) : row.text)
                    .font(.system(size: pointSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.90))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .transaction { $0.animation = nil }
        .frame(width: max(0, width), height: pointSize * 1.65, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(romanize ? LyricsRomanizer.romanize(row.text) : row.text)
    }

    private var timedWords: some View {
        let layout = LyricTextLayout.cached(words: row.words, rowID: row.id, romanize: romanize,
            pointSize: pointSize, width: width, displayScale: displayScale)
        let previousLayout = previousRow.map { LyricTextLayout.cached(words: $0.words, rowID: $0.id,
            romanize: romanize, pointSize: pointSize, width: width, displayScale: displayScale) }
        return LyricCanvasView(row: row, previousRow: previousRow, layout: layout, previousLayout: previousLayout,
            displayStart: displayStart, elapsed: elapsed, sampleDate: sampleDate, playbackRate: playbackRate,
            isPlaying: isPlaying, reduceMotion: reduceMotion, pointSize: pointSize)
    }
}
