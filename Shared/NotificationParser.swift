import Foundation
import CryptoKit

/// Shared semantic text normalization and fingerprints; no AX snapshot model.
enum NotificationParser {
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }
            .filter { ![0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069].contains($0.value) }
        let value = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func fingerprint(fields: [String?]) -> String {
        // Length-prefixing avoids collisions between fields containing separators.
        let canonical = fields.map { field in
            let value = clean(field) ?? ""
            return "\(value.utf8.count):\(value)"
        }.joined()
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
