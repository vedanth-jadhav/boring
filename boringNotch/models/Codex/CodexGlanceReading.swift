import Foundation

/// Only the subscription's primary windows belong in the compact display.
/// A passed reset never implies a fresh allowance until the server confirms it.
struct CodexGlanceReading {
    let quota: CodexQuotaSnapshot?
    let now: Date
    let hasError: Bool
    var error: String?

    var session: CodexQuotaSnapshot.Window? { quota?.windows.first { $0.id == "codex-session" } }
    var weekly: CodexQuotaSnapshot.Window? { quota?.windows.first { $0.id == "codex-weekly" } }
    var recorded: Bool { quota?.isLocal == true || hasError || quota.map { now.timeIntervalSince($0.updatedAt) > 60 } == true }
    var status: String {
        guard quota != nil else { return hasError ? "Usage unavailable · open Codex to connect" : "Reading Codex usage…" }
        return recorded ? "Saved reading" : "Live allowance"
    }

    func remaining(_ window: CodexQuotaSnapshot.Window?) -> String {
        guard let window, !window.needsRefresh(at: now) else { return "—" }
        return "\(Int(window.remaining.rounded()))%"
    }

    func reset(_ window: CodexQuotaSnapshot.Window?) -> String {
        guard let date = window?.resetsAt else { return "—" }
        guard date > now else { return "…" }
        let minutes = max(1, Int(ceil(date.timeIntervalSince(now) / 60)))
        if minutes >= 1_440 { return "\(minutes / 1_440)d \((minutes % 1_440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    func window(for limit: CodexPillLimit) -> CodexQuotaSnapshot.Window? {
        limit == .session ? session : weekly
    }

    func state(for limit: CodexPillLimit) -> CodexGlanceStatus {
        guard let window = window(for: limit) else {
            return quota == nil && !hasError ? .loading : .unavailable
        }
        if window.needsRefresh(at: now) { return hasError ? .unavailable : .resetting }
        if recorded || now.timeIntervalSince(quota?.updatedAt ?? .distantPast) > 60 { return .saved }
        return .current
    }

    func value(for limit: CodexPillLimit, metric: CodexPillMetric) -> String {
        let window = window(for: limit)
        if metric == .reset { return reset(window) }
        if metric == .used {
            guard let window, !window.needsRefresh(at: now) else { return "—" }
            return "\(Int(window.usedPercent.rounded()))% used"
        }
        return remaining(window)
    }

    func secondaryValue(for limit: CodexPillLimit, metric: CodexPillMetric) -> String? {
        metric == .remainingAndReset ? reset(window(for: limit)) : nil
    }

    func accessibilityLabel(for limit: CodexPillLimit) -> String {
        let window = window(for: limit)
        return "Codex \(limit.title) allowance. \(remaining(window)) remaining. Reset time \(reset(window)). \(status). \(error ?? "")"
    }

    var help: String {
        var lines = ["Codex · \(status)", description(session, title: "5-hour"), description(weekly, title: "Weekly")]
        if let updated = quota?.updatedAt { lines.append("Last read \(updated.formatted(date: .omitted, time: .standard))") }
        if let error { lines.append(error) }
        lines.append("Click for details or to retry")
        return lines.joined(separator: "\n")
    }

    private func description(_ window: CodexQuotaSnapshot.Window?, title: String) -> String {
        let resetDate = window?.resetsAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "unavailable"
        if window?.needsRefresh(at: now) == true { return "\(title): reset due · waiting for a fresh reading" }
        return "\(title): \(remaining(window)) left · resets in \(reset(window)) (\(resetDate))"
    }
}
