import AppKit

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
    private static let cache: NSCache<NSString, LyricTextLayout> = {
        let cache = NSCache<NSString, LyricTextLayout>()
        cache.countLimit = 240
        return cache
    }()

    static func cached(words: [LyricLine.Word], rowID: String? = nil, romanize: Bool, pointSize: CGFloat, width: CGFloat) -> LyricTextLayout {
        let identity = rowID ?? words.map(\.text).joined(separator: "\u{001F}")
        let key = "\(romanize)|\(pointSize)|\(width)|\(identity)"
        if let layout = cache.object(forKey: key as NSString) { return layout }
        let layout = LyricTextLayout(words: words, romanize: romanize, pointSize: pointSize, width: width)
        cache.setObject(layout, forKey: key as NSString)
        return layout
    }

    private init(words: [LyricLine.Word], romanize: Bool, pointSize: CGFloat, width: CGFloat) {
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
        pageForWord = ranges.flatMap { range in Array(repeating: range, count: range.count) }
        accessibilityText = text.joined(separator: " ")
    }
}
