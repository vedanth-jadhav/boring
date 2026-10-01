import Foundation

/// All timestamps are absolute seconds on the media element's clock.
struct LyricLine: Equatable {
    struct Word: Equatable {
        let text: String
        let start: Double
        let end: Double
        var isBackground: Bool = false
    }

    let start: Double
    let end: Double?
    let text: String
    var words: [Word] = []
    var isBackground: Bool = false

    func resolvedWords(until fallbackEnd: Double) -> [Word] {
        if !words.isEmpty { return assigningVocalRoles(to: words) }
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let finish = max(start + 0.1, end ?? fallbackEnd)
        // Line-only sources have no exact word alignment. Weight by syllable
        // length rather than making a short article last as long as a long word.
        let weights = tokens.map { Double(max(2, $0.count)) }
        let total = weights.reduce(0, +)
        var cursor = start
        let estimated = zip(tokens, weights).map { text, weight in
            let next = cursor + (finish - start) * weight / total
            defer { cursor = next }
            return Word(text: text, start: cursor, end: next)
        }
        return assigningVocalRoles(to: estimated)
    }

    private func assigningVocalRoles(to words: [Word]) -> [Word] {
        var depth = 0
        let entireLineIsBacking = isBackground || (text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("(")
            && text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(")"))
        return words.map { word in
            let opens = word.text.filter { $0 == "(" || $0 == "（" }.count
            let closes = word.text.filter { $0 == ")" || $0 == "）" }.count
            let backing = word.isBackground || entireLineIsBacking || depth > 0 || opens > 0
            depth = max(0, depth + opens - closes)
            return Word(text: word.text, start: word.start, end: word.end, isBackground: backing)
        }
    }

    func effectiveEnd(nextStart: Double?, duration: Double) -> Double {
        if let end { return end }
        // Rich word ends can overlap the next lead line. Never truncate them.
        if let lastWordEnd = words.map(\.end).max() { return lastWordEnd }
        return nextStart ?? min(duration, start + max(2, Double(text.split(whereSeparator: \.isWhitespace).count) * 0.45))
    }
}

extension LyricLine {
    /// Supports repeated line stamps, fractional seconds and enhanced word LRC.
    static func parseLRC(_ lrc: String) -> [LyricLine] {
        guard let lineRegex = try? NSRegularExpression(pattern: #"\[(\d+):(\d{2}(?:\.\d+)?)\]"#),
              let wordRegex = try? NSRegularExpression(pattern: #"<(\d+):(\d{2}(?:\.\d+)?)>"#) else { return [] }
        func time(_ match: NSTextCheckingResult, in text: NSString) -> Double {
            (Double(text.substring(with: match.range(at: 1))) ?? 0) * 60
                + (Double(text.substring(with: match.range(at: 2))) ?? 0)
        }
        var result: [LyricLine] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let source = raw as NSString
            let stamps = lineRegex.matches(in: raw, range: NSRange(location: 0, length: source.length))
            guard let lastStamp = stamps.last else { continue }
            let content = source.substring(from: NSMaxRange(lastStamp.range))
            let nsContent = content as NSString
            let marks = wordRegex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
            let text = wordRegex.stringByReplacingMatches(in: content, range: NSRange(location: 0, length: nsContent.length), withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            for stamp in stamps {
                let shift = time(stamp, in: source) - time(stamps[0], in: source)
                var words: [Word] = []
                for (index, mark) in marks.enumerated() {
                    // A terminal word marker is an end time, not another word.
                    guard index + 1 < marks.count else { continue }
                    let next = marks[index + 1]
                    let token = nsContent.substring(with: NSRange(location: NSMaxRange(mark.range), length: next.range.location - NSMaxRange(mark.range)))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !token.isEmpty {
                        words.append(Word(text: token, start: time(mark, in: nsContent) + shift, end: time(next, in: nsContent) + shift))
                    }
                }
                // Only use exact alignment if it covers the whole line. Missing
                // terminal markers should never silently drop the final word.
                if words.map(\.text).joined(separator: " ") != text { words = [] }
                result.append(LyricLine(start: time(stamp, in: source), end: nil, text: text, words: words))
            }
        }
        return result.sorted { $0.start < $1.start }
    }
}
