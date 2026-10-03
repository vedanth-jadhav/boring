import Foundation

/// Prepares timing once per lyrics response; display frames only sample it.
struct LyricTimeline {
    struct Entry {
        let index: Int
        let line: LyricLine
        let end: Double
        let nextStart: Double?
        let words: [LyricLine.Word]
        let vocalRows: LyricVocalFrame.PreparedRows
    }

    let entries: [Entry]
    let hasConcurrentVocals: Bool
    let hasWordTimings: Bool
    let displayBoundaries: [Double]
    private let frameBoundaries: [Double]
    private let prefixEnds: [Double]
    private let displayEntries: [Entry]

    init(lines: [LyricLine]) {
        let identity = UUID().uuidString
        var prepared: [Entry] = []
        var concurrent = false
        var nextStarts = [Double?](repeating: nil, count: lines.count)
        var nextDistinctStart: Double?
        for index in lines.indices.reversed() {
            if index + 1 < lines.count, lines[index + 1].start > lines[index].start {
                nextDistinctStart = lines[index + 1].start
            }
            nextStarts[index] = nextDistinctStart
        }
        for index in lines.indices {
            let line = lines[index]
            let next = nextStarts[index]
            let end = line.effectiveEnd(nextStart: next, duration: .greatestFiniteMagnitude)
            let words = line.resolvedWords(until: end)
            if words.contains(where: \.isBackground) { concurrent = true }
            if let previous = prepared.last, previous.end > line.start { concurrent = true }
            prepared.append(Entry(index: index, line: line, end: end, nextStart: next, words: words,
                vocalRows: .init(words: words, identity: "\(identity):\(index)", hasExactTiming: !line.words.isEmpty)))
        }
        entries = prepared
        hasWordTimings = lines.contains { !$0.words.isEmpty }
        frameBoundaries = Array(Set(prepared.flatMap { entry in
            [entry.line.start, entry.end]
                + (entry.vocalRows.secondary?.activityIntervals.flatMap { [$0.lowerBound, $0.upperBound] } ?? [])
                + entry.vocalRows.backing.flatMap { [$0.start, $0.end] }
        }.filter { $0.isFinite && $0 >= 0 })).sorted()
        displayBoundaries = Array(Set(prepared.flatMap { entry in
            [entry.line.start, entry.end] + entry.words.flatMap { [$0.start, $0.end] }
        }.filter { $0.isFinite && $0 >= 0 })).sorted()
        let readable = prepared.filter { !$0.words.isEmpty }
        let lead = readable.filter { $0.words.contains { !$0.isBackground } }
        displayEntries = lead.isEmpty ? readable : lead
        hasConcurrentVocals = concurrent
        var maximum = -Double.infinity
        prefixEnds = prepared.map { maximum = max(maximum, $0.end); return maximum }
    }

    func displayBucket(at elapsed: Double) -> Int {
        var low = 0
        var high = frameBoundaries.count
        while low < high {
            let mid = (low + high) / 2
            if frameBoundaries[mid] <= elapsed { low = mid + 1 } else { high = mid }
        }
        return low
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
