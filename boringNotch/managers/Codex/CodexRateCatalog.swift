import Foundation

struct CodexRateCatalog: Codable, Sendable {
    struct Rate: Codable, Sendable {
        let input: Double
        let cached: Double?
        let cacheWrite: Double?
        let output: Double
        func estimate(_ tokens: CodexTokenTotals) -> Double? {
            guard tokens.cached == 0 || cached != nil, tokens.cacheWrite == 0 || cacheWrite != nil else { return nil }
            return (Double(tokens.input - tokens.cached - tokens.cacheWrite) * input
                    + Double(tokens.cached) * (cached ?? 0)
                    + Double(tokens.cacheWrite) * (cacheWrite ?? 0)
                    + Double(tokens.output) * output) / 1_000_000
        }
    }

    var rates: [String: Rate]
    var updatedAt: Date
    static let sourceURL = URL(string: "https://developers.openai.com/api/docs/pricing")!

    func rate(for model: String) -> Rate? {
        if let exact = rates[model] { return exact }
        // Only strip an explicit snapshot date. Never substitute a different model.
        if model.range(of: "-\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil {
            return rates[String(model.dropLast(11))]
        }
        return nil
    }

    static func parse(html: String, now: Date = Date()) throws -> Self {
        func matches(_ pattern: String, in text: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
            let ns = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        }
        func plain(_ text: String) -> String {
            text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&nbsp;", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var rates: [String: Rate] = [:]
        // The page embeds the full official Standard catalog in its Astro props,
        // including rows hidden behind “All models”. Decode that before the visible tables.
        for attributes in matches("<astro-island\\b([^>]+)>", in: html) where attributes.contains("TextTokenPricingTables") {
            guard let encoded = matches("props=\"([^\"]+)\"", in: attributes).first else { continue }
            let decoded = encoded.replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
            guard let json = try? JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [String: Any],
                  let tier = json["tier"] as? [Any], tier.count == 2, tier[1] as? String == "standard",
                  let taggedRows = json["rows"] as? [Any], taggedRows.count == 2,
                  let rows = taggedRows[1] as? [[Any]] else { continue }
            for taggedRow in rows {
                guard taggedRow.count == 2, let cells = taggedRow[1] as? [[Any]], cells.count == 4 || cells.count == 5,
                      cells.allSatisfy({ $0.count == 2 }), let label = cells[0][1] as? String else { continue }
                let model = label.components(separatedBy: " (").first ?? label
                guard model.range(of: "^(gpt-|o[134](-|$)|codex-)[a-z0-9.-]*$", options: .regularExpression) != nil,
                      rates[model] == nil else { continue }
                func number(_ index: Int) -> Double? {
                    guard let value = cells[index][1] as? NSNumber, value.doubleValue.isFinite, value.doubleValue >= 0 else { return nil }
                    return value.doubleValue
                }
                guard let input = number(1), let output = number(cells.count - 1) else { continue }
                rates[model] = Rate(input: input, cached: number(2), cacheWrite: cells.count == 5 ? number(3) : nil, output: output)
            }
        }
        for table in matches("<table\\b[^>]*>(.*?)</table>", in: html) {
            let rows = matches("<tr\\b[^>]*>(.*?)</tr>", in: table)
            guard let header = rows.first(where: { plain($0).contains("Cached input") }) else { continue }
            let columns = matches("<t[hd]\\b[^>]*>(.*?)</t[hd]>", in: header).map(plain)
            guard let inputIndex = columns.firstIndex(of: "Input"), let outputIndex = columns.firstIndex(of: "Output"),
                  let cachedIndex = columns.firstIndex(of: "Cached input") else { continue }
            let writeIndex = columns.firstIndex(of: "Cache writes")
            for row in rows {
                let cells = matches("<t[hd]\\b[^>]*>(.*?)</t[hd]>", in: row).map(plain)
                guard let model = cells.first, model.range(of: "^(gpt-|o[134]-|codex-)[a-z0-9.-]+$", options: .regularExpression) != nil,
                      rates[model] == nil, cells.count > max(inputIndex, outputIndex) else { continue }
                func number(_ index: Int) -> Double? {
                    guard cells.indices.contains(index), cells[index].hasPrefix("$") else { return nil }
                    let string = cells[index].dropFirst().replacingOccurrences(of: ",", with: "")
                    guard let value = Double(string), value.isFinite, value >= 0 else { return nil }
                    return value
                }
                guard let input = number(inputIndex), let output = number(outputIndex) else { continue }
                // The official page emits Standard first, followed by Batch/Flex/Fast.
                // Keep the first exact model row, with the first (short-context) columns.
                rates[model] = Rate(input: input, cached: number(cachedIndex), cacheWrite: writeIndex.flatMap(number), output: output)
            }
        }
        guard rates.count >= 3 else { throw CodexUsageClient.Failure.pricingChanged }
        return Self(rates: rates, updatedAt: now)
    }
}
