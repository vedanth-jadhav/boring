import AppKit
import CoreText
import SwiftUI

/// SwiftUI supplies immutable row geometry. A native display link repaints only
/// this reading lane, without invalidating the notch's layout every frame.
struct LyricCanvasView: NSViewRepresentable {
    let row: LyricVocalFrame.Row
    let previousRow: LyricVocalFrame.Row?
    let layout: LyricTextLayout
    let previousLayout: LyricTextLayout?
    let displayStart: Double
    let elapsed: Double
    let sampleDate: Date
    let playbackRate: Double
    let isPlaying: Bool
    let reduceMotion: Bool
    let pointSize: CGFloat

    func makeNSView(context: Context) -> LyricPaintView { LyricPaintView() }
    func updateNSView(_ view: LyricPaintView, context: Context) { view.update(self) }
    static func dismantleNSView(_ view: LyricPaintView, coordinator: ()) { view.stop() }

    func position(at date: Date) -> Double {
        LyricPlaybackClock.position(anchorPosition: elapsed, anchorDate: sampleDate, at: date,
            rate: playbackRate, playing: isPlaying, duration: .greatestFiniteMagnitude)
    }

    func draw(in context: CGContext, size: CGSize, at position: Double) {
        let anchor = row.anchor(at: position)
        let range = layout.pageForWord.indices.contains(anchor) ? layout.pageForWord[anchor] : row.words.indices
        let first = row.words[range].min { $0.start < $1.start }
        let start = range.lowerBound > 0 ? first?.start ?? displayStart : displayStart
        let duration = min(0.16, max(0, (first?.end ?? start) - start) * 0.45)
        let handoff = LyricHandoffPhase(start: start, elapsed: position, duration: duration,
            reduceMotion: reduceMotion || (first?.start ?? start) > start + 0.01)
        if handoff.outgoingOpacity > 0 {
            if range.lowerBound > 0 {
                paint(layer(row, layout: layout, range: layout.pageForWord[range.lowerBound - 1]),
                    in: context, size: size, position: position, opacity: handoff.outgoingOpacity)
            } else if let previousRow, let previousLayout, let previousRange = previousLayout.pages.last {
                paint(layer(previousRow, layout: previousLayout, range: previousRange),
                    in: context, size: size, position: position, opacity: handoff.outgoingOpacity)
            }
        }
        paint(layer(row, layout: layout, range: range), in: context, size: size, position: position,
              opacity: handoff.incomingOpacity)
    }

    private func layer(_ row: LyricVocalFrame.Row, layout: LyricTextLayout, range: Range<Int>) -> LyricPaintLayer {
        LyricPaintLayer(layout: layout, words: row.words, visibleRange: range, exactTiming: row.hasExactTiming,
            phrase: row.highlightsWords ? nil : .init(text: row.text, start: row.start, end: row.end))
    }

    private func paint(_ layer: LyricPaintLayer, in context: CGContext, size: CGSize, position: Double,
                       opacity: Double) {
        let layout = layer.layout
        guard let last = layer.visibleRange.last, layout.widths.indices.contains(last) else { return }
        let feather = pointSize * 0.85
        let light = layer.light(at: position, feather: feather)
        for index in layer.visibleRange where layout.text.indices.contains(index) && layer.words.indices.contains(index) {
            let phase = LyricWordPhase(word: layer.phrase ?? layer.words[index], elapsed: position)
            let halfWidth = layout.widths[index] / 2
            let glyph = layout.glyph(at: index)
            let rect = CGRect(x: -halfWidth - layout.glyphPadding, y: -glyph.size.height / 2,
                              width: glyph.size.width, height: glyph.size.height)
            context.saveGState()
            context.setAlpha(opacity)
            context.translateBy(x: 2 + layout.offsets[index] + halfWidth, y: size.height / 2)
            if let mask = glyph.mask {
                context.clip(to: rect, mask: mask)
                if !reduceMotion, let light, light.index == index, let gradient = Self.trailGradient {
                    let x = light.front - layout.offsets[index] - halfWidth
                    context.drawLinearGradient(gradient, start: CGPoint(x: x - 2 * feather, y: 0),
                        end: CGPoint(x: x + feather, y: 0),
                        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                } else {
                    let ink: Double = !layer.exactTiming ? 0.90
                        : (phase.progress >= 1 || reduceMotion && phase.isActive ? 0.94 : 0.60)
                    context.setFillColor(gray: 1, alpha: ink)
                    context.fill(rect)
                }
            } else {
                // Low-memory fallback keeps the text readable without a mask allocation.
                let ink = !layer.exactTiming ? 0.90
                    : (reduceMotion && phase.isActive ? 0.94 : phase.shimmerOpacity(at: 0.5))
                context.setAlpha(opacity * ink)
                context.textPosition = CGPoint(x: -halfWidth, y: glyph.baseline - glyph.size.height / 2)
                CTLineDraw(glyph.line, context)
            }
            context.restoreGState()
        }
    }

    // One soft leading edge, with the sung text staying quietly lit behind it.
    private static let trailGradient = CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(),
        colorComponents: [1, 0.94, 1, 0.97, 1, 1, 1, 0.60], locations: [0, 0.33, 0.66, 1], count: 4)
}
