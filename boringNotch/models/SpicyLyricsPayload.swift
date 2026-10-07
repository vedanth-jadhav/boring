import Foundation

/// Text and alignment always travel together; only provider stamps count as exact.
struct SpicyLyricsPayload: Codable {
    let plain: String
    let lines: [LyricLine]
    let attribution: LyricAttribution

    var precision: Int { lines.contains { !$0.words.isEmpty } ? 2 : (lines.isEmpty ? 0 : 1) }

    static func parse(_ data: Data) -> SpicyLyricsPayload? {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (envelope["Status"] as? Int) == 200,
              let body = envelope["Body"] as? [String: Any],
              let type = body["Type"] as? String else { return nil }
        let content = body["Content"] as? [[String: Any]] ?? []
        var lines: [LyricLine] = []
        var plainRows: [String] = []
        for entry in content {
            guard (entry["Type"] as? String) != "Interlude" else { continue }
            let lead = entry["Lead"] as? [String: Any] ?? entry
            let text = textAndWords(lead).text
            if !text.isEmpty { plainRows.append(text) }
            if type != "Static", let line = timedLine(lead, background: false) { lines.append(line) }
            for background in entry["Background"] as? [[String: Any]] ?? [] {
                let backingText = textAndWords(background).text
                if !backingText.isEmpty { plainRows.append(backingText) }
                if type != "Static", let line = timedLine(background, background: true) { lines.append(line) }
            }
        }
        let plain = plainRows.isEmpty ? (body["Text"] as? String ?? "") : plainRows.joined(separator: "\n")
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Stable ordering keeps a lead before its simultaneous backing vocal.
        lines = lines.enumerated().sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
        return SpicyLyricsPayload(plain: plain, lines: lines,
            attribution: LyricAttribution(source: body["source"] as? String ?? "spicy_lyrics",
                                           upload: body["UploadAttribution"] as? [String: Any]))
    }

    private static func timedLine(_ vocal: [String: Any], background: Bool) -> LyricLine? {
        let parsed = textAndWords(vocal)
        guard !parsed.text.isEmpty,
              let start = number(vocal["StartTime"]) ?? parsed.words.first?.start,
              start.isFinite, start >= 0 else { return nil }
        let rawEnd = number(vocal["EndTime"]) ?? parsed.words.last?.end
        let end = rawEnd.flatMap { $0.isFinite && $0 > start ? $0 : nil }
        let words = parsed.words.allSatisfy { $0.start >= start } ? parsed.words : []
        return LyricLine(start: start, end: end, text: parsed.text,
                         words: words.map { .init(text: $0.text, start: $0.start, end: $0.end, isBackground: background) },
                         isBackground: background)
    }

    private static func textAndWords(_ vocal: [String: Any]) -> (text: String, words: [LyricLine.Word]) {
        guard let syllables = vocal["Syllables"] as? [[String: Any]], !syllables.isEmpty else {
            return ((vocal["Text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        var words: [LyricLine.Word] = []
        var tokens: [String] = []
        var token = ""
        var start: Double?
        var end: Double?
        var valid = true
        func finishWord() {
            let text = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                tokens.append(text)
                if let start, let end, start.isFinite, end.isFinite, start >= 0, end > start {
                    words.append(.init(text: text, start: start, end: end))
                } else { valid = false }
            }
            token = ""; start = nil; end = nil
        }
        for syllable in syllables {
            guard let text = syllable["Text"] as? String else { valid = false; continue }
            let syllableStart = number(syllable["StartTime"])
            let syllableEnd = number(syllable["EndTime"])
            if let syllableStart, let syllableEnd,
               syllableStart.isFinite, syllableEnd.isFinite, syllableStart >= 0, syllableEnd > syllableStart {
                if let end, syllableStart < end { valid = false }
            } else { valid = false }
            if token.isEmpty { start = syllableStart }
            token += text
            end = syllableEnd
            if syllable["IsPartOfWord"] as? Bool != true { finishWord() }
        }
        finishWord()
        let text = (vocal["Text"] as? String) ?? tokens.joined(separator: " ")
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), valid ? words : [])
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return (value as? String).flatMap(Double.init)
    }
}
