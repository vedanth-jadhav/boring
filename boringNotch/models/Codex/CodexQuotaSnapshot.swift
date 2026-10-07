import Foundation

struct CodexQuotaSnapshot: Codable, Sendable {
    struct Window: Codable, Identifiable, Sendable {
        let id: String
        let title: String
        let usedPercent: Double
        let resetsAt: Date?
        var remaining: Double { max(0, min(100, 100 - usedPercent)) }
        func needsRefresh(at date: Date) -> Bool { resetsAt.map { $0 <= date } ?? false }
    }

    struct ResetCredit: Codable, Identifiable, Sendable {
        let id: String
        let title: String
        let expiresAt: Date?
    }

    var windows: [Window]
    var plan: String?
    var credits: String?
    var unlimitedCredits = false
    var resetCount: Int?
    var resetCredits: [ResetCredit] = []
    var updatedAt: Date
    var isLocal = false

    static func parse(_ json: [String: Any], at date: Date, local: Bool = false) -> Self? {
        var windows: [Window] = []
        func append(_ limits: [String: Any], prefix: String, name: String?) {
            for (key, suffix) in [(local ? "primary" : "primary_window", "session"),
                                  (local ? "secondary" : "secondary_window", "weekly")] {
                guard let raw = limits[key] as? [String: Any],
                      let used = raw["used_percent"] as? Double, used.isFinite, (0...100).contains(used) else { continue }
                let seconds = (raw["limit_window_seconds"] as? Double) ?? ((raw["window_minutes"] as? Double).map { $0 * 60 })
                let duration: String
                if let seconds, seconds >= 604_800 { duration = "Weekly" }
                else if let seconds, seconds >= 3_600 { duration = "\(Int(seconds / 3_600))-hour" }
                else { duration = suffix == "weekly" ? "Weekly" : "Session" }
                let reset = (raw[local ? "resets_at" : "reset_at"] as? Double)
                    .map { Date(timeIntervalSince1970: $0) }
                    ?? (raw["reset_after_seconds"] as? Double).map { date.addingTimeInterval($0) }
                windows.append(Window(id: "\(prefix)-\(suffix)", title: name.map { "\($0) · \(duration)" } ?? duration,
                                      usedPercent: used, resetsAt: reset))
            }
        }
        append(local ? json : json["rate_limit"] as? [String: Any] ?? [:], prefix: "codex", name: nil)
        for extra in json["additional_rate_limits"] as? [[String: Any]] ?? [] {
            let name = extra["limit_name"] as? String ?? extra["metered_feature"] as? String ?? "Model limit"
            append(extra["rate_limit"] as? [String: Any] ?? [:], prefix: name, name: name)
        }
        let credits = json["credits"] as? [String: Any]
        let reset = json["rate_limit_reset_credits"] as? [String: Any]
        guard !windows.isEmpty || credits != nil || json["plan_type"] as? String != nil else { return nil }
        return Self(windows: windows, plan: json["plan_type"] as? String,
                    credits: credits?["balance"] as? String,
                    unlimitedCredits: credits?["unlimited"] as? Bool ?? false,
                    resetCount: reset?["available_count"] as? Int, updatedAt: date, isLocal: local)
    }

    mutating func applyResetCredits(_ json: [String: Any], now: Date) {
        resetCount = json["available_count"] as? Int ?? resetCount
        resetCredits = (json["credits"] as? [[String: Any]] ?? []).compactMap { raw in
            guard raw["status"] as? String == "available", raw["is_supported_by_plan"] as? Bool != false,
                  let id = raw["id"] as? String else { return nil }
            let expiry = (raw["expires_at"] as? String).flatMap(CodexLogScanner.parseDate)
            guard expiry.map({ $0 > now }) ?? true else { return nil }
            return ResetCredit(id: id, title: raw["title"] as? String ?? "Allowance reset", expiresAt: expiry)
        }.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }
}
