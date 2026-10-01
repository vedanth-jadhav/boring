import SwiftUI

struct KaraokeLyricLineView: View {
    let words: [LyricLine.Word]
    let elapsed: Double
    let romanize: Bool
    let width: CGFloat
    let pointSize: CGFloat
    let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout = LyricTextLayout.cached(words: words, romanize: romanize, pointSize: pointSize, width: width)
        let anchor = words.lastIndex { elapsed >= $0.start } ?? 0
        let phase = words.indices.contains(anchor) ? LyricWordPhase(word: words[anchor], elapsed: elapsed).progress : 0
        let focus = layout.starts.indices.contains(anchor)
            ? layout.starts[anchor] + layout.widths[anchor] * phase : 0
        let offset = -min(max(0, layout.totalWidth - width), max(0, focus - width * 0.46))

        let shortWords = words.filter { $0.end - $0.start < 0.24 }.count
        let useReadingPages = layout.totalWidth > width && words.count >= 4 && shortWords * 2 >= words.count
        let visibleRange = useReadingPages ? (layout.pages.first { $0.contains(anchor) } ?? words.indices) : words.indices
        let pageFade = words.indices.contains(anchor) ? min(0.16, max(0.07, (words[anchor].end - words[anchor].start) * 0.6)) : 0.12

        ZStack(alignment: .leading) {
            HStack(spacing: layout.spacing) {
                ForEach(visibleRange, id: \.self) { index in
                    ShimmeringLyricWord(text: layout.text[index], pointSize: pointSize,
                                       phase: LyricWordPhase(word: words[index], elapsed: elapsed),
                                       shimmer: isPlaying && !reduceMotion)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            // Follow the word's continuous audio phase. A 420 ms scroll animation
            // would still be catching up when the next short word starts.
            .offset(x: useReadingPages ? 0 : offset)
            .id(visibleRange.lowerBound)
            .transition(.opacity)
        }
        // Fast phrases stay still for reading. Crossfade whole-word pages;
        // continuously panning a rap verse makes the glyphs harder to track.
        .animation(reduceMotion ? nil : .easeInOut(duration: pageFade), value: visibleRange.lowerBound)
        .frame(width: max(0, width), height: pointSize * 1.65, alignment: .leading)
        .clipped()
        .mask {
            if layout.totalWidth > width && !reduceMotion && !useReadingPages {
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .white, location: 0.025),
                                       .init(color: .white, location: 0.975),
                                       .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            } else {
                Rectangle()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(layout.text.joined(separator: " "))
    }
}
