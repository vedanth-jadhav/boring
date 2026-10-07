import Foundation

struct LyricVocalFrame {
    struct Row: Identifiable {
        let id: String
        let words: [LyricLine.Word]
        let isBackground: Bool
        let hasExactTiming: Bool
        let hasEstimatedTiming: Bool
        var highlightsWords: Bool { hasExactTiming || hasEstimatedTiming }
        let text: String
        let start: Double
        let end: Double
        let activityIntervals: [Range<Double>]
        private let shortestWordDuration: Double
        private let anchorStarts: [Double]
        private let anchorIndices: [Int]

        init(id: String, words: [LyricLine.Word], isBackground: Bool, hasExactTiming: Bool,
             hasEstimatedTiming: Bool = false) {
            self.id = id
            self.words = words
            self.isBackground = isBackground
            self.hasExactTiming = hasExactTiming
            self.hasEstimatedTiming = hasEstimatedTiming
            shortestWordDuration = words.map { $0.end - $0.start }.filter { $0.isFinite && $0 > 0 }.min() ?? 1
            text = words.map(\.text).joined(separator: " ")
            start = words.map(\.start).min() ?? 0
            end = words.map(\.end).max() ?? 0
            var intervals: [Range<Double>] = []
            for word in words.sorted(by: { $0.start < $1.start }) where word.start < word.end {
                if let last = intervals.last, word.start <= last.upperBound {
                    intervals[intervals.count - 1] = last.lowerBound..<max(last.upperBound, word.end)
                } else { intervals.append(word.start..<word.end) }
            }
            activityIntervals = intervals
            // Preserve source-order lastIndex semantics even if a provider's
            // overlapping word stamps are not sorted by start time.
            let anchors = words.enumerated().filter { $0.element.start.isFinite }
                .sorted { $0.element.start < $1.element.start }
            anchorStarts = anchors.map { $0.element.start }
            var highestIndex = 0
            anchorIndices = anchors.map { highestIndex = max(highestIndex, $0.offset); return highestIndex }
        }

        func anchor(at elapsed: Double) -> Int {
            var low = 0
            var high = anchorStarts.count
            while low < high {
                let mid = (low + high) / 2
                if anchorStarts[mid] <= elapsed { low = mid + 1 } else { high = mid }
            }
            return low > 0 ? anchorIndices[low - 1] : 0
        }

        func isActive(at elapsed: Double) -> Bool {
            activityIntervals.contains { $0.contains(elapsed) }
        }

        func animationInterval(rate: Double) -> Double {
            // One display clock for the entire row. Dense vocals need more
            // samples; a held note or line sheen can use half the frame rate.
            hasExactTiming || highlightsWords && shortestWordDuration / max(0.01, rate) < 0.25 ? 1.0 / 60 : 1.0 / 30
        }
    }

    /// Vocal roles and overlap groups depend on the response, not the clock.
    struct PreparedRows {
        let primary: Row?
        let secondary: Row?
        let backing: [Row]

        init(words: [LyricLine.Word], identity: String, hasExactTiming: Bool, hasEstimatedTiming: Bool = false) {
            let foreground = words.filter { !$0.isBackground }
            let overlapping = words.indices.filter { index in
                let word = words[index]
                return word.isBackground && (foreground.isEmpty || foreground.contains {
                    word.start < $0.end && $0.start < word.end
                })
            }
            let splitIndices = Set(overlapping)
            let inline = words.enumerated().filter { !splitIndices.contains($0.offset) }.map(\.element)
            // An entirely backing line is readable in the primary position;
            // in later positions it belongs to the concurrent vocal lane.
            let primaryWords = foreground.isEmpty ? words : inline
            primary = primaryWords.isEmpty ? nil : Row(id: "\(identity):lead", words: primaryWords,
                isBackground: foreground.isEmpty, hasExactTiming: hasExactTiming, hasEstimatedTiming: hasEstimatedTiming)
            secondary = inline.isEmpty ? nil : Row(id: "\(identity):lead", words: inline,
                isBackground: foreground.isEmpty, hasExactTiming: hasExactTiming, hasEstimatedTiming: hasEstimatedTiming)
            var groups: [[Int]] = []
            for index in overlapping {
                if groups.last?.last == index - 1 {
                    groups[groups.count - 1].append(index)
                } else { groups.append([index]) }
            }
            backing = groups.map { group in
                Row(id: "\(identity):backing:\(group[0])", words: group.map { words[$0] },
                    isBackground: true, hasExactTiming: hasExactTiming, hasEstimatedTiming: hasEstimatedTiming)
            }
        }
    }

    let rows: [Row]

    init(entries: [LyricTimeline.Entry], elapsed: Double) {
        var lead: [Row] = []
        var backing: [Row] = []
        for (position, entry) in entries.enumerated() {
            let prepared = entry.vocalRows
            if position == 0 {
                if let row = prepared.primary { lead.append(row) }
            } else if let row = prepared.secondary,
                      row.isActive(at: elapsed) {
                lead.append(row)
            }
            // Entirely backing lines in the primary position stay inline.
            if position != 0 || prepared.primary?.isBackground != true {
                backing.append(contentsOf: prepared.backing.filter { elapsed >= $0.start && elapsed < $0.end })
            }
        }
        rows = Array((lead + backing).prefix(2))
    }
}
