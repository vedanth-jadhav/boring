import AppKit
import CoreText

/// Romanisation and glyph measurement happen once, rather than on every
/// display refresh. Timing remains attached to the original source words.
final class LyricTextLayout {
    let text: [String]
    let widths: [CGFloat]
    let pointSizes: [CGFloat]
    let spacing: CGFloat
    let pages: [Range<Int>]
    let pageForWord: [Range<Int>]
    let accessibilityText: String
    let offsets: [CGFloat]
    let glyphPadding: CGFloat = 2
    struct Glyph {
        let mask: CGImage?
        let size: CGSize
        let line: CTLine
        let baseline: CGFloat
        let cost: Int
    }
    private let glyphs: [Glyph]
    private let cacheCost: Int

    func glyph(at index: Int) -> Glyph { glyphs[index] }

    private static let cache: NSCache<NSString, LyricTextLayout> = {
        let cache = NSCache<NSString, LyricTextLayout>()
        cache.countLimit = 240
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    static func cached(words: [LyricLine.Word], rowID: String? = nil, romanize: Bool, pointSize: CGFloat,
                       width: CGFloat, displayScale: CGFloat = 2) -> LyricTextLayout {
        let identity = rowID ?? words.map(\.text).joined(separator: "\u{001F}")
        let scale = displayScale.isFinite ? min(4, max(2, displayScale)) : 2
        let key = "\(romanize)|\(pointSize)|\(width)|\(scale)|\(identity)"
        if let layout = cache.object(forKey: key as NSString) { return layout }
        let layout = LyricTextLayout(words: words, romanize: romanize, pointSize: pointSize, width: width, displayScale: scale)
        cache.setObject(layout, forKey: key as NSString, cost: layout.cacheCost)
        return layout
    }

    private init(words: [LyricLine.Word], romanize: Bool, pointSize: CGFloat, width: CGFloat, displayScale: CGFloat) {
        text = words.map { romanize ? LyricsRomanizer.romanize($0.text) : $0.text }
        let font = NSFont.systemFont(ofSize: pointSize, weight: .medium)
        let measured = text.map { ($0 as NSString).size(withAttributes: [.font: font]).width }
        let available = max(1, width - 4)
        // Transliteration can expand a source token considerably. Fit a lone
        // oversized token once, keeping its spelling and original timing intact.
        let fitted = zip(text, measured).map { token, measure -> (CGFloat, CGFloat) in
            var size = pointSize
            var width = measure
            // System-font optical sizing is not perfectly linear. Re-measure
            // oversized tokens until the actual glyphs fit, only on cache miss.
            while width > available, size > 0.01 {
                size = max(0.01, size * min(0.98, available / width))
                width = (token as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium)]).width
            }
            return (size, width)
        }
        pointSizes = fitted.map { $0.0 }
        widths = fitted.map { $0.1 }
        let preparedGlyphs = zip(text, fitted).map { token, metrics in
            Self.rasterizedGlyph(token, pointSize: metrics.0, width: metrics.1, scale: displayScale)
        }
        glyphs = preparedGlyphs
        cacheCost = preparedGlyphs.reduce(0) { $0 + $1.cost }
        let gap = pointSize * 0.28
        spacing = gap
        var ranges: [Range<Int>] = []
        var start = 0
        var used: CGFloat = 0
        for index in widths.indices {
            let additional = widths[index] + (index == start ? 0 : gap)
            if index > start, used + additional > max(1, width - 4) {
                ranges.append(start..<index)
                start = index
                used = widths[index]
            } else { used += additional }
        }
        if start < widths.count { ranges.append(start..<widths.count) }
        pages = ranges
        var positions = Array(repeating: CGFloat.zero, count: widths.count)
        for page in ranges {
            var x: CGFloat = 0
            for index in page {
                positions[index] = x
                x += widths[index] + gap
            }
        }
        offsets = positions
        pageForWord = ranges.flatMap { range in Array(repeating: range, count: range.count) }
        accessibilityText = text.joined(separator: " ")
    }

    private static func rasterizedGlyph(_ text: String, pointSize: CGFloat, width: CGFloat,
                                        scale: CGFloat) -> Glyph {
        let font = NSFont.systemFont(ofSize: pointSize, weight: .medium)
        let padding: CGFloat = 2
        let height = ceil(font.ascender - font.descender + font.leading)
        let size = CGSize(width: width + 2 * padding, height: height + 2 * padding)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let baseline = padding - font.descender
        func glyph(mask: CGImage?, size: CGSize, cost: Int) -> Glyph {
            Glyph(mask: mask, size: size, line: line, baseline: baseline, cost: cost)
        }
        if let context = CGContext(data: nil, width: max(1, Int(ceil(size.width * scale))),
            height: max(1, Int(ceil(size.height * scale))), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.scaleBy(x: scale, y: scale)
            context.textPosition = CGPoint(x: padding, y: baseline)
            CTLineDraw(line, context)
            if let image = context.makeImage() {
                let renderedSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
                return glyph(mask: image, size: renderedSize, cost: context.bytesPerRow * context.height)
            }
        }
        return glyph(mask: nil, size: size, cost: 0)
    }
}
