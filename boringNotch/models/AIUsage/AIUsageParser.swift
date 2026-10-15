import Foundation

enum AIUsageParser {
    static func claude(_ json: [String: Any], at date: Date) -> CodexQuotaSnapshot? {
        let names = [("five_hour", "5-hour"), ("seven_day", "Weekly"),
                     ("seven_day_sonnet", "Sonnet · Weekly"), ("seven_day_opus", "Opus · Weekly")]
        let windows = names.compactMap { key, title -> CodexQuotaSnapshot.Window? in
            guard let raw = json[key] as? [String: Any], let used = raw["utilization"] as? Double,
                  used.isFinite, (0...100).contains(used) else { return nil }
            let id = key == "five_hour" ? "codex-session" : key == "seven_day" ? "codex-weekly" : key
            return .init(id: id, title: title, usedPercent: used,
                         resetsAt: (raw["resets_at"] as? String).flatMap(CodexLogScanner.parseDate))
        }
        guard !windows.isEmpty else { return nil }
        return .init(windows: windows, updatedAt: date)
    }

    static func grokCredits(_ json: [String: Any], at date: Date) -> CodexQuotaSnapshot? {
        guard let config = json["config"] as? [String: Any],
              let used = config["creditUsagePercent"] as? Double, used.isFinite, (0...100).contains(used) else { return nil }
        let period = config["currentPeriod"] as? [String: Any]
        let reset = (period?["end"] as? String ?? config["billingPeriodEnd"] as? String).flatMap(CodexLogScanner.parseDate)
        return .init(windows: [.init(id: "grok-credits", title: "Plan credits", usedPercent: used, resetsAt: reset)],
                     plan: config["subscriptionTier"] as? String, updatedAt: date)
    }

    static func antigravityRemote(_ json: [String: Any], at date: Date) -> CodexQuotaSnapshot? {
        let summary = json["response"] as? [String: Any] ?? json["summary"] as? [String: Any] ?? json
        let groups: [[String: Any]] = (summary["groups"] as? [[String: Any]] ?? []).map { group in
            let buckets: [[String: Any]] = (group["buckets"] as? [[String: Any]] ?? []).map { bucket in
                var normalized = bucket
                normalized["id"] = bucket["bucketId"] ?? bucket["id"]
                normalized["name"] = bucket["displayName"] ?? bucket["name"]
                normalized["remaining_fraction"] = bucket["remainingFraction"] ?? (bucket["remaining"] as? [String: Any])?["remainingFraction"]
                normalized["reset_time"] = bucket["resetTime"]
                return normalized
            }
            return ["name": group["displayName"] ?? group["name"] ?? "Models", "buckets": buckets]
        }
        return antigravity(["status": "SUCCESS", "command": ["name": "usage", "data": ["groups": groups]]], at: date)
    }

    static func antigravity(_ json: [String: Any], at date: Date) -> CodexQuotaSnapshot? {
        guard json["status"] as? String == "SUCCESS", let command = json["command"] as? [String: Any],
              command["name"] as? String == "usage", let data = command["data"] as? [String: Any] else { return nil }
        var windows: [CodexQuotaSnapshot.Window] = []
        for group in data["groups"] as? [[String: Any]] ?? [] {
            let name = group["name"] as? String ?? "Models"
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                guard let id = bucket["id"] as? String, bucket["disabled"] as? Bool != true,
                      let remaining = bucket["remaining_fraction"] as? Double,
                      remaining.isFinite, (0...1).contains(remaining) else { continue }
                let window = (bucket["window"] as? String)?.lowercased()
                guard window == "weekly" || window == "5h" else { continue }
                let weekly = window == "weekly"
                windows.append(.init(id: id, title: "\(name) · \(weekly ? "Weekly" : "5-hour")",
                                     usedPercent: 100 * (1 - remaining),
                                     resetsAt: (bucket["reset_time"] as? String).flatMap(CodexLogScanner.parseDate)))
            }
        }
        guard !windows.isEmpty else { return nil }
        // The glance shows the most constrained model family for the selected window.
        for (weekly, id) in [(false, "codex-session"), (true, "codex-weekly")] {
            if let window = windows.filter({ $0.title.hasSuffix(weekly ? "Weekly" : "5-hour") })
                .max(by: { $0.usedPercent < $1.usedPercent }) {
                windows.append(.init(id: id, title: weekly ? "Weekly" : "5-hour",
                                     usedPercent: window.usedPercent, resetsAt: window.resetsAt))
            }
        }
        return .init(windows: windows, updatedAt: date)
    }
}
