import Foundation

/// A lightweight fallback for South Asian LRC. Prepared once per response;
/// these weights are estimates, never provider-supplied word timestamps.
enum LyricPhoneticTiming {
    static func isSupported(in lines: [LyricLine]) -> Bool {
        var hints = Set<String>()
        for line in lines {
            if line.text.unicodeScalars.contains(where: {
                (0x0900...0x097F).contains($0.value) || (0x0A00...0x0A7F).contains($0.value)
                    || (0x0600...0x06FF).contains($0.value)
            }) { return true }
            for token in line.text.lowercased().split(whereSeparator: { !$0.isLetter }) {
                if romanizedHints.contains(String(token)) { hints.insert(String(token)) }
                if hints.count >= 2 { return true }
            }
        }
        return false
    }

    static func weight(of token: String) -> Double {
        // Native script and its displayed romanization must share a clock.
        let phonetic = LyricsRomanizer.romanize(token).lowercased()
        var syllables = 0.0
        var vowelRun = 0
        var consonants = 0
        func finishVowel() {
            if vowelRun > 0 { syllables += vowelRun > 1 ? 1.25 : 1 }
            vowelRun = 0
        }
        for character in phonetic {
            if "aeiou".contains(character) { vowelRun += 1 }
            else {
                finishVowel()
                if character.isLetter { consonants += 1 }
            }
        }
        finishVowel()
        // Consonant clusters add articulation, not whole syllables. Dots and
        // ellipses mark a held vocal; commas must not become extra syllables.
        let hold = token.contains("..") || token.contains("…") ? 1.0 : 0
        return max(1, syllables) + min(0.4, Double(consonants) * 0.06) + hold
    }

    private static let romanizedHints: Set<String> = [
        "aankhon", "aankhein", "apna", "apni", "banda", "chhanv", "dekho", "dil", "dungi",
        "hain", "hoon", "ishq", "jaana", "jana", "jhoota", "kaam", "karna", "keh",
        "khud", "khwaab", "kyun", "majboor", "mera", "mere", "meri", "mujhe", "naal", "nahi",
        "nahin", "paun", "premi", "pyaar", "pyar", "rahe", "raha", "rahi", "sachhi", "samajh",
        "sharma", "tera", "tere", "teri", "tujh", "tujhe", "tumhara", "vekhya", "yaara", "zindagi"
    ]
}
