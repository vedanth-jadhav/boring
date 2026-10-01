import Foundation

/// Prepares timing once per lyrics response; display frames only sample it.
struct LyricTimeline {
    struct Entry {
        let index: Int
        let line: LyricLine
        let end: Double
        let nextStart: Double?
        let words: [LyricLine.Word]
    }

    let entries: [Entry]
    let hasConcurrentVocals: Bool
    private let prefixEnds: [Double]
    private let displayEntries: [Entry]

    init(lines: [LyricLine]) {
        var prepared: [Entry] = []
        var concurrent = false
        for index in lines.indices {
            let line = lines[index]
            let next = lines.dropFirst(index + 1).first { $0.start > line.start }?.start
            let end = line.effectiveEnd(nextStart: next, duration: .greatestFiniteMagnitude)
            let words = line.resolvedWords(until: end)
            if words.contains(where: \.isBackground) { concurrent = true }
            if let previous = prepared.last, previous.end > line.start { concurrent = true }
            prepared.append(Entry(index: index, line: line, end: end, nextStart: next, words: words))
        }
        entries = prepared
        let readable = prepared.filter { !$0.words.isEmpty }
        let lead = readable.filter { $0.words.contains { !$0.isBackground } }
        displayEntries = lead.isEmpty ? readable : lead
        hasConcurrentVocals = concurrent
        var maximum = -Double.infinity
        prefixEnds = prepared.map { maximum = max(maximum, $0.end); return maximum }
    }

    /// Reading and singing have different lifetimes: retain the current lead
    /// through silence, but never extend any word's highlight timestamps.
    func displayed(at elapsed: Double, duration: Double) -> [Entry] {
        guard elapsed.isFinite, elapsed >= 0, !displayEntries.isEmpty else { return [] }
        var low = 0
        var high = displayEntries.count
        while low < high {
            let mid = (low + high) / 2
            if displayEntries[mid].line.start <= elapsed { low = mid + 1 } else { high = mid }
        }
        // Preview the first phrase during the intro, then hold each phrase
        // until its successor starts. Empty LRC markers cannot blank the row.
        let primary = displayEntries[max(0, low - 1)]
        return [primary] + active(at: elapsed, duration: duration).reversed().filter { $0.index != primary.index }
    }

    func active(at elapsed: Double, duration: Double) -> [Entry] {
        guard elapsed.isFinite, elapsed >= 0, elapsed < duration else { return [] }
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].line.start <= elapsed { low = mid + 1 } else { high = mid }
        }
        var index = low - 1
        var result: [Entry] = []
        // Prefix maxima let us stop without scanning the rest of the song,
        // while still finding a long backing vocal under a later lead line.
        while index >= 0, prefixEnds[index] > elapsed {
            let entry = entries[index]
            if elapsed < entry.end, !entry.line.text.isEmpty { result.append(entry) }
            index -= 1
        }
        return result.reversed()
    }
}
