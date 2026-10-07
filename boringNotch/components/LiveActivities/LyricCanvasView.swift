import SwiftUI

/// Glyph positions and sizes remain fixed. Only the ink changes, using one
/// paint surface and the row's shared playback clock.
struct LyricCanvasView: View {
    let layout: LyricTextLayout
    let words: [LyricLine.Word]
    let visibleRange: Range<Int>
    let position: Double
    let exactTiming: Bool
    let reduceMotion: Bool
    let pointSize: CGFloat

    var body: some View {
        Canvas { context, size in
            for index in visibleRange where layout.text.indices.contains(index) {
                let phase = LyricWordPhase(word: words[index], elapsed: position)
                var wordContext = context
                wordContext.translateBy(x: 2 + layout.offsets[index] + layout.widths[index] / 2,
                                        y: size.height / 2)
                var glyph = layout.glyph(at: index, in: context)
                glyph.shading = .linearGradient(
                    HighlightedLyricWord.ink(phase, exactTiming: exactTiming, reduceMotion: reduceMotion,
                        feather: Double(min(0.28, max(0.08, pointSize * 0.85 / max(1, layout.widths[index]))))),
                    startPoint: CGPoint(x: -layout.widths[index] / 2, y: 0),
                    endPoint: CGPoint(x: layout.widths[index] / 2, y: 0))
                wordContext.draw(glyph, at: CGPoint(x: -layout.widths[index] / 2, y: 0), anchor: .leading)
            }
        }
        .allowsHitTesting(false)
    }
}
