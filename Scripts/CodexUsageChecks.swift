import Foundation
import CryptoKit

@main struct CodexUsageChecks {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func row(_ type: String, _ payload: [String: Any], date: Date) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": date.ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)), "payload": payload], options: [.sortedKeys])
        data.append(10); return data
    }

    static func tokens(_ input: Int64, _ cached: Int64, _ output: Int64, date: Date) throws -> Data {
        try row("event_msg", ["type": "token_count", "info": ["total_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output, "reasoning_output_tokens": output / 2]]], date: date)
    }

    static func total(_ report: CodexLogScanner.Report) -> CodexTokenTotals {
        report.daily.values.reduce(into: CodexTokenTotals()) { $0.add($1) }
    }

    static func main() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("codex-checks-\(UUID().uuidString)")
        let digest = SHA256.hash(data: Data(home.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let cacheFile = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.vedanth.boringnotch.octave/Codex/usage-\(digest).json")
        defer { try? fm.removeItem(at: home); try? fm.removeItem(at: cacheFile) }
        try fm.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let now = Date()
        let claude = AIUsageParser.claude(["five_hour": ["utilization": 25.0, "resets_at": now.addingTimeInterval(60).ISO8601Format()],
                                           "seven_day": ["utilization": 61.0]], at: now)!
        expect(claude.windows.first?.remaining == 75, "Claude usage means consumed allowance, not remaining")
        expect(claude.windows.last?.id == "codex-weekly", "Claude weekly limits must work in the glance")
        expect(AIUsageParser.claude(["five_hour": ["utilization": -1.0]], at: now) == nil, "Malformed Claude usage cannot become a valid allowance")
        let buckets: [[String: Any]] = [["id": "weekly", "name": "Weekly", "window": "weekly", "remaining_fraction": 0.8],
                                        ["id": "session", "window": "5h", "remaining_fraction": 0.3],
                                        ["id": "invalid", "remaining_fraction": 1.2]]
        let antiJSON: [String: Any] = ["status": "SUCCESS", "command": ["name": "usage", "data": ["groups": [["name": "Gemini", "buckets": buckets],
                                         ["name": "Claude", "buckets": [["id": "other", "window": "5h", "remaining_fraction": 0.1]]]]]]]
        let anti = AIUsageParser.antigravity(antiJSON, at: now)!
        expect(anti.windows.count == 5, "Antigravity rejects invalid buckets and supplies two glance windows")
        expect(anti.windows.first(where: { $0.id == "codex-session" })?.usedPercent == 90, "Glance must show the most constrained model family")
        expect(AIUsageParser.antigravity(["status": "FAILURE"], at: now) == nil, "A failed CLI command must not look like a fresh quota")
        expect(AIUsageParser.grokCredits(["config": [:]], at: now) == nil, "Missing Grok usage must never imply zero usage")
        expect(AIUsageParser.grokCredits(["config": ["creditUsagePercent": Double.nan]], at: now) == nil, "Non-finite Grok usage must be rejected")
        expect(AIUsageParser.grokCredits(["config": ["creditUsagePercent": 40.0]], at: now)?.windows.first?.remaining == 60, "Grok reports plan credits separately from session limits")

        let remote = AIUsageParser.antigravityRemote(["groups": [["displayName": "Gemini", "buckets": [["bucketId": "weekly", "window": "weekly", "remainingFraction": 0.4, "resetTime": now.addingTimeInterval(100).ISO8601Format()]]]]], at: now)!
        expect(remote.windows.first?.usedPercent == 60, "Remote Antigravity fields must preserve consumed quota")
        expect(AIUsageParser.antigravityRemote(["groups": [["buckets": [["bucketId": "unknown", "window": "unknown", "remainingFraction": 0.8]]]]], at: now) == nil, "Unknown quota cadences must not masquerade as 5-hour windows")
        let grokQuota = AIUsageParser.grokCredits(["config": ["creditUsagePercent": 40.0]], at: now)!
        let grokReading = CodexGlanceReading(quota: grokQuota, now: now, hasError: false, providerTitle: "Grok")
        expect(grokReading.title(for: .session) == "Credits" && grokReading.value(for: .weekly, metric: .remaining) == "60%", "Grok credit usage must not be labeled as a 5-hour or weekly allowance")
        print("PASS: Claude, Antigravity, Grok parser validation")
        let sessionWindow = CodexQuotaSnapshot.Window(id: "codex-session", title: "5-hour", usedPercent: 37,
                                                      resetsAt: now.addingTimeInterval(120))
        let weeklyWindow = CodexQuotaSnapshot.Window(id: "codex-weekly", title: "Weekly", usedPercent: 9,
                                                     resetsAt: now.addingTimeInterval(86_400))
        let liveQuota = CodexQuotaSnapshot(windows: [sessionWindow, weeklyWindow], updatedAt: now)
        let liveReading = CodexGlanceReading(quota: liveQuota, now: now, hasError: false)
        expect(liveReading.value(for: .weekly, metric: .remaining) == "91%", "Selected weekly reading must not silently become session usage")
        expect(liveReading.value(for: .session, metric: .used) == "37% used", "Used allowance must be distinguishable from remaining allowance")
        expect(liveReading.value(for: .session, metric: .reset) == "2m", "Reset reading uses the selected window")
        expect(liveReading.state(for: .session) == .current, "Fresh live readings should be current")
        let expiredReading = CodexGlanceReading(quota: liveQuota, now: now.addingTimeInterval(121), hasError: false)
        expect(expiredReading.remaining(sessionWindow) == "—", "A passed reset must not invent a fresh allowance")
        expect(expiredReading.state(for: .session) == .resetting, "Passed reset should request a new reading")
        let failedReset = CodexGlanceReading(quota: liveQuota, now: now.addingTimeInterval(121), hasError: true)
        expect(failedReset.state(for: .session) == .unavailable, "Failed reset refresh must not spin forever")
        let cachedReading = CodexGlanceReading(quota: liveQuota, now: now, hasError: true)
        expect(cachedReading.state(for: .weekly) == .saved, "Cached usage after a network failure must be visibly marked")
        expect(cachedReading.remaining(weeklyWindow) == "91%", "Preserve the last valid reading during network errors")
        expect(CodexGlanceReading(quota: nil, now: now, hasError: false).state(for: .session) == .loading, "Initial state should be loading")
        expect(CodexGlanceReading(quota: nil, now: now, hasError: true).state(for: .session) == .unavailable, "Failed sign-in must show an unavailable state")
        let restoredCache = try JSONDecoder().decode(CodexCachedQuota.self, from: JSONEncoder().encode(CodexCachedQuota(identity: "test-account", snapshot: liveQuota)))
        expect(restoredCache.identity == "test-account" && restoredCache.snapshot.windows.first?.usedPercent == 37, "Persistent snapshots must preserve account identity and allowance")
        let file = home.appendingPathComponent("sessions/session.jsonl")
        var data = try row("session_meta", ["id": "parent"], date: now)
        data += try row("turn_context", ["model": "gpt-6.1-sol"], date: now)
        data += try tokens(1_000, 400, 100, date: now)
        data += try tokens(1_000, 400, 100, date: now) // unchanged repeated snapshot
        data += try row("turn_context", ["model": "gpt-6-astra"], date: now)
        data += try tokens(1_600, 600, 180, date: now)
        try data.write(to: file)
        let scanner = CodexLogScanner()
        let initial = try await scanner.scan(home: home, now: now)
        print("Initial scanner: \(initial.fileCount) files, \(initial.daily.count) model days, \(total(initial).total) tokens")
        expect(total(initial).total == 1_780, "Duplicate cumulative snapshots must not count twice")
        expect(total(initial).cached == 600, "Cached input must remain a subset of input")
        expect(total(initial).reasoning == 90, "Reasoning is included in output, not added again")
        let sol = initial.daily.first { $0.key.hasSuffix("|gpt-6.1-sol") }!.value
        expect(sol.total == 1_100, "Attribute each delta to its turn model")
        let unchanged = try await scanner.scan(home: home, now: now)
        expect(total(unchanged) == total(initial), "Unchanged cache scan must be idempotent")
        let savedAttributes = try fm.attributesOfItem(atPath: cacheFile.path)
        for _ in 0..<5 { _ = try await scanner.scan(home: home, now: now) }
        _ = try await CodexLogScanner().scan(home: home, now: now)
        let warmAttributes = try fm.attributesOfItem(atPath: cacheFile.path)
        expect(savedAttributes[.systemFileNumber] as? NSNumber == warmAttributes[.systemFileNumber] as? NSNumber
               && savedAttributes[.modificationDate] as? Date == warmAttributes[.modificationDate] as? Date,
               "Unchanged scans, including a reloaded scanner, must not rewrite the persistent cache")

        let next = try tokens(2_000, 900, 220, date: now.addingTimeInterval(5))
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: next.dropLast())
        let partial = try await scanner.scan(home: home, now: now)
        expect(total(partial) == total(initial), "Do not consume partially appended JSONL")
        try handle.write(contentsOf: Data([10])); try handle.close()
        let appended = try await scanner.scan(home: home, now: now)
        expect(total(appended).total == 2_220, "Append must resume at last complete row")
        let reloaded = try await CodexLogScanner().scan(home: home, now: now)
        expect(total(reloaded) == total(appended), "Disk cache must preserve baseline and aggregates")

        let fork = home.appendingPathComponent("sessions/fork.jsonl")
        var forkData = try row("session_meta", ["id": "child", "forked_from_id": "parent", "timestamp": now.ISO8601Format()], date: now)
        forkData += try row("turn_context", ["model": "gpt-6.1-sol"], date: now)
        forkData += try tokens(1_000, 400, 100, date: now)
        forkData += try tokens(1_600, 600, 180, date: now.addingTimeInterval(0.02))
        forkData += try tokens(1_900, 700, 210, date: now.addingTimeInterval(8))
        try forkData.write(to: fork)
        let withFork = try await scanner.scan(home: home, now: now)
        expect(total(withFork).total == 2_550, "Exclude fork replay, count new child usage")

        try fm.createDirectory(at: home.appendingPathComponent("archived_sessions"), withIntermediateDirectories: true)
        try fm.copyItem(at: file, to: home.appendingPathComponent("archived_sessions/copy.jsonl"))
        let copied = try await scanner.scan(home: home, now: now)
        expect(total(copied).total == 2_550, "Deduplicate copied session IDs across archives")
        try Data("malformed row\n".utf8).write(to: file)
        let truncated = try await scanner.scan(home: home, now: now)
        expect(total(truncated).total == 2_550, "Copied archive still preserves original usage after truncation")
        let afterRetention = Calendar.current.date(byAdding: .day, value: 31, to: now)!
        let expired = try await scanner.scan(home: home, now: afterRetention)
        expect(expired.fileCount == 0 && total(expired).total == 0, "A changed 30-day cutoff must invalidate the warm report and prune expired files")
        let restored = try await scanner.scan(home: home, now: now)
        expect(total(restored).total == 2_550, "A changed cutoff must rebuild the correct report")
        try fm.removeItem(at: fork)
        let removed = try await scanner.scan(home: home, now: now)
        expect(total(removed).total == 2_220, "Removing a file must invalidate the warm report")
        let boundaryFile = home.appendingPathComponent("sessions/boundary.jsonl")
        let boundaryDate = CodexUsagePeriod.month.start(at: now).addingTimeInterval(60)
        try tokens(10, 0, 1, date: boundaryDate).write(to: boundaryFile)
        let atBoundary = try await scanner.scan(home: home, now: now)
        expect(total(atBoundary).total == 2_231, "Include usage on the oldest retained day")
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let shifted = try await scanner.scan(home: home, now: tomorrow)
        expect(total(shifted).total == 2_220, "A new day must prune expired totals in otherwise unchanged files")
        let shiftedReloaded = try await CodexLogScanner().scan(home: home, now: tomorrow)
        expect(total(shiftedReloaded).total == 2_220, "Daily pruning must persist without rereading unchanged files")

        let html = "<table><tr><th>Model</th><th>Input</th><th>Cached input</th><th>Cache writes</th><th>Output</th></tr><tr><td>gpt-6.1-sol</td><td>$2.00</td><td>$0.10</td><td>$2.50</td><td>$10.00</td></tr><tr><td>gpt-6-astra</td><td>$10</td><td>$1</td><td>$12.50</td><td>$50</td></tr><tr><td>gpt-6-luna</td><td>$0.10</td><td>$0.01</td><td>$0.125</td><td>$0.50</td></tr></table>"
        let rates = try CodexRateCatalog.parse(html: html)
        expect(rates.rate(for: "gpt-6.1-sol")?.input == 2, "Parse exact published model rates")
        expect(rates.rate(for: "gpt-6.1-sol-2026-10-01")?.input == 2, "Allow explicit dated aliases")
        expect(rates.rate(for: "gpt-6-sol") == nil, "Never substitute a similarly named model")
        expect(abs(rates.rate(for: "gpt-6.1-sol")!.estimate(sol)! - 0.00224) < 0.000001, "Charge cached tokens once and output including reasoning once")
        do { _ = try CodexRateCatalog.parse(html: "changed"); fatalError("Malformed pricing must fail closed") } catch {}

        let json: [String: Any] = ["plan_type": "plus", "rate_limit": ["primary_window": ["used_percent": 25, "limit_window_seconds": 18_000, "reset_at": now.addingTimeInterval(60).timeIntervalSince1970]], "rate_limit_reset_credits": ["available_count": 1]]
        var quota = CodexQuotaSnapshot.parse(json, at: now)!
        expect(quota.windows.first?.remaining == 75, "Report remaining, not consumed allowance")
        expect(quota.windows.first?.title == "5-hour", "Use window duration from response")
        expect(quota.windows.first!.needsRefresh(at: now.addingTimeInterval(61)), "Expired window requires refresh, not fabricated replenishment")
        quota.applyResetCredits(["available_count": 1, "credits": [["id": "active", "status": "available", "expires_at": now.addingTimeInterval(100).ISO8601Format()], ["id": "expired", "status": "available", "expires_at": now.addingTimeInterval(-100).ISO8601Format()]]], now: now)
        expect(quota.resetCredits.count == 1, "Exclude expired reset credits")
        print("PASS: counting, model attribution, incremental and persistent cache, partial writes, fork replay, archives, truncation, pricing, resets")

        if CommandLine.arguments.contains("--live") {
            let realHome = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            let client = CodexUsageClient()
            let prices = try await client.pricing(force: true)
            print("LIVE: \(prices.rates.count) exact published rates; account limits require interactive sign-in")
            let start = Date()
            let local = try await CodexLogScanner().scan(home: realHome)
            print("SCAN: \(local.fileCount) recent files; \(total(local).total) tokens; \(String(format: "%.2f", Date().timeIntervalSince(start))) seconds")
            let warmStart = Date()
            _ = try await CodexLogScanner().scan(home: realHome)
            print("WARM: \(String(format: "%.3f", Date().timeIntervalSince(warmStart))) seconds")
        }
    }
}
