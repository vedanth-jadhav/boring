import Foundation

struct LyricVocalFrame {
    struct Row: Identifiable {
        let id: String
        let words: [LyricLine.Word]
        let isBackground: Bool
    }

    let rows: [Row]

    init(entries: [LyricTimeline.Entry], elapsed: Double) {
        var lead: [Row] = []
        var backing: [Row] = []
        for (position, entry) in entries.enumerated() {
            let foreground = entry.words.filter { !$0.isBackground }
            // Parentheses alone do not imply a second singer. Sequential
            // ad-libs belong inline; split only genuinely overlapping vocals.
            let overlapping = entry.words.indices.filter { index in
                let word = entry.words[index]
                return word.isBackground && (foreground.isEmpty ? position != 0 : foreground.contains {
                    word.start < $0.end && $0.start < word.end
                })
            }
            let splitIndices = Set(overlapping)
            let inline = entry.words.enumerated().filter { !splitIndices.contains($0.offset) }.map(\.element)
            let identity = "\(entry.index):\(entry.line.start):\(entry.line.text)"
            if !inline.isEmpty, position == 0 || inline.contains(where: { elapsed >= $0.start && elapsed < $0.end }) {
                lead.append(Row(id: "\(identity):lead", words: inline, isBackground: foreground.isEmpty))
            }

            // Separate ad-libs in the same source line must not share one
            // lifetime or leave an extra row visible before/after they sing.
            var groups: [[Int]] = []
            for index in overlapping {
                if groups.last?.last == index - 1 {
                    groups[groups.count - 1].append(index)
                } else {
                    groups.append([index])
                }
            }
            for group in groups {
                let words = group.map { entry.words[$0] }
                guard let start = words.map(\.start).min(), let end = words.map(\.end).max(),
                      elapsed >= start, elapsed < end else { continue }
                backing.append(Row(id: "\(identity):backing:\(group[0])", words: words, isBackground: true))
            }
        }
        // The first entry is the readable lead, held through silence. The
        // second lane exists only while another vocal is actually present.
        rows = Array((lead + backing).prefix(2))
    }
}
