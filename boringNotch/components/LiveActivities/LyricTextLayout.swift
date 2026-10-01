import AppKit

/// Romanisation and glyph measurement happen once, rather than on every
/// display refresh. Timing remains attached to the original source words.
final class LyricTextLayout {
    let text: [String]
    let widths: [CGFloat]
    let starts: [CGFloat]
    let totalWidth: CGFloat
    let spacing: CGFloat
    let pages: [Range<Int>]
    private static let cache: NSCache<NSString, LyricTextLayout> = {
        let cache = NSCache<NSString, LyricTextLayout>()
        cache.countLimit = 240
        return cache
    }()

    static func cached(words: [LyricLine.Word], romanize: Bool, pointSize: CGFloat, width: CGFloat) -> LyricTextLayout {
        let key = "\(romanize)|\(pointSize)|\(width)|" + words.map(\.text).joined(separator: "\u{001F}")
        if let layout = cache.object(forKey: key as NSString) { return layout }
        let layout = LyricTextLayout(words: words, romanize: romanize, pointSize: pointSize, width: width)
        cache.setObject(layout, forKey: key as NSString)
        return layout
    }

    private init(words: [LyricLine.Word], romanize: Bool, pointSize: CGFloat, width: CGFloat) {
        text = words.map { romanize ? LyricsRomanizer.romanize($0.text) : $0.text }
        let font = NSFont.systemFont(ofSize: pointSize, weight: .medium)
        widths = text.map { ($0 as NSString).size(withAttributes: [.font: font]).width }
        let gap = pointSize * 0.28
        spacing = gap
        var cursor: CGFloat = 0
        starts = widths.map { size in defer { cursor += size + gap }; return cursor }
        totalWidth = max(0, cursor - gap)
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
    }
}
