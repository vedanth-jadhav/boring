import Foundation

/// Prepared geometry stays shared while the canvas paints a phrase handoff.
struct LyricPaintLayer {
    let layout: LyricTextLayout
    let words: [LyricLine.Word]
    let visibleRange: Range<Int>
    let exactTiming: Bool
    let phrase: LyricLine.Word?

    /// The light exists only inside a supplied word interval. A vocal pause
    /// has no cursor; neither word length nor the next line estimates speech.
    func light(at position: Double, feather: CGFloat) -> (index: Int, front: CGFloat)? {
        guard exactTiming, let index = visibleRange.last(where: {
            LyricWordPhase(word: words[$0], elapsed: position).isActive
        }) else { return nil }
        let phase = LyricWordPhase(word: words[index], elapsed: position)
        return (index, layout.offsets[index] - feather + (layout.widths[index] + 3 * feather) * phase.progress)
    }
}
