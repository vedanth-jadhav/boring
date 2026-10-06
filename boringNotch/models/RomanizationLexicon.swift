import Foundation

/// Human-attested spellings in a sorted, memory-mapped table. Each lookup
/// touches O(log n) records without parsing or retaining a dictionary.
final class RomanizationLexicon {
    private let data: Data
    let count: Int
    private let payloadStart: Int

    private static let directory: URL? = {
        // The CLI regression runner has no application resource bundle.
        if let path = ProcessInfo.processInfo.environment["BORING_ROMANIZATION_RESOURCES"] {
            return URL(fileURLWithPath: path)
        }
        return Bundle.main.resourceURL?.appendingPathComponent("Romanization", isDirectory: true)
    }()
    private static let hindi = load("hi")
    private static let punjabi = load("pa")
    private static let urdu = load("ur")

    private static func load(_ language: String) -> RomanizationLexicon? {
        guard let directory else { return nil }
        return RomanizationLexicon(url: directory.appendingPathComponent(language + ".lexicon"))
    }

    static func romanization(for word: String, script: Int) -> String? {
        switch script {
        case 1: return hindi?.romanization(for: word)
        case 2: return punjabi?.romanization(for: word)
        case 3: return urdu?.romanization(for: word)
        default: return nil
        }
    }

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 16,
              data.prefix(8) == Data("BNRL0001".utf8) else { return nil }
        let count = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian) }
        guard count > 0, count <= 1_000_000 else { return nil }
        let payloadStart = 12 + (count + 1) * 4
        guard payloadStart < data.count else { return nil }
        let lastOffset = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 12 + count * 4, as: UInt32.self).littleEndian) }
        guard lastOffset == data.count - payloadStart else { return nil }
        self.data = data
        self.count = count
        self.payloadStart = payloadStart
    }

    func romanization(for word: String) -> String? {
        let key = Array(word.utf8)
        return data.withUnsafeBytes { raw -> String? in
            let bytes = raw.bindMemory(to: UInt8.self)
            func offset(_ index: Int) -> Int {
                payloadStart + Int(raw.loadUnaligned(fromByteOffset: 12 + index * 4, as: UInt32.self).littleEndian)
            }
            var low = 0
            var high = count
            while low < high {
                let mid = (low + high) / 2
                let start = offset(mid)
                let end = offset(mid + 1)
                guard start >= payloadStart, start < end, end <= bytes.count else { return nil }
                var cursor = start
                var index = 0
                while cursor < end, bytes[cursor] != 0, index < key.count, bytes[cursor] == key[index] {
                    cursor += 1
                    index += 1
                }
                guard cursor < end else { return nil }
                if index == key.count, bytes[cursor] == 0 {
                    guard cursor + 1 < end, bytes[end - 1] == 0 else { return nil }
                    return String(decoding: bytes[(cursor + 1)..<(end - 1)], as: UTF8.self)
                }
                if bytes[cursor] == 0 || (index < key.count && bytes[cursor] < key[index]) { low = mid + 1 }
                else { high = mid }
            }
            return nil
        }
    }
}
