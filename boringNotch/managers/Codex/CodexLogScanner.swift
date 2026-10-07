import Foundation
import CryptoKit

actor CodexLogScanner {
    struct Report: Sendable {
        var daily: [String: CodexTokenTotals] = [:]
        var quota: CodexQuotaSnapshot?
        var fileCount = 0
        var unreadableCount = 0
    }

    private struct FileState: Codable {
        var offset: UInt64 = 0
        var size: UInt64 = 0
        var modified: Date = .distantPast
        var inode: UInt64 = 0
        var sessionID: String?
        var model = "Unknown model"
        var previous = CodexTokenTotals()
        var hasPrevious = false
        var forked = false
        var forkDate: Date?
        var replayDone = false
        var replayBurst = false
        var replayLastDate: Date?
        var pendingTokens: CodexTokenTotals?
        var pendingModel: String?
        var daily: [String: CodexTokenTotals] = [:]
        var quota: CodexQuotaSnapshot?
    }

    private struct Cache: Codable {
        var version = 1
        var home: String
        var timezone: String
        var files: [String: FileState] = [:]
    }

    private var cache: Cache?
    private var cacheURL: URL?
    private let tokenMarker = Data("\"token_count\"".utf8)
    private let contextMarker = Data("\"turn_context\"".utf8)
    private let metaMarker = Data("\"session_meta\"".utf8)

    static func parseDate(_ value: String) -> Date? {
        // ISO8601FormatStyle handles both whole seconds and fractional timestamps.
        if let date = try? Date(value, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)) { return date }
        return try? Date(value, strategy: .iso8601)
    }

    func scan(home: URL, now: Date = Date()) async throws -> Report {
        loadCache(home: home)
        guard var current = cache else { return Report() }
        let cutoff = CodexUsagePeriod.month.start(at: now)
        let oldestDay = Self.dayKey(cutoff)
        var paths: [(URL, UInt64, Date, UInt64)] = []
        var report = Report()
        let fm = FileManager.default
        for directory in ["sessions", "archived_sessions"] {
            let root = home.appendingPathComponent(directory)
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                 options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else {
                report.unreadableCount += 1; continue
            }
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension == "jsonl" else { continue }
                try Task.checkCancellation()
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      let modified = attrs[.modificationDate] as? Date, modified >= cutoff,
                      let size = (attrs[.size] as? NSNumber)?.uint64Value else { continue }
                paths.append((url, size, modified, (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0))
            }
        }
        paths.sort { $0.2 > $1.2 }
        let retainedPaths = Set(paths.map { $0.0.path })
        current.files = current.files.filter { retainedPaths.contains($0.key) }
        var sessionIDs = Set<String>()
        defer {
            cache = current
            if let cacheURL, let data = try? JSONEncoder().encode(current) {
                try? data.write(to: cacheURL, options: [.atomic])
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
            }
        }
        for (url, size, modified, inode) in paths {
            try Task.checkCancellation()
            var state = current.files[url.path] ?? FileState()
            if state.inode != inode || size < state.offset || (size == state.size && modified != state.modified) {
                state = FileState()
            }
            state.daily = state.daily.filter { String($0.key.prefix(10)) >= oldestDay }
            if size != state.size || modified != state.modified || state.offset < size {
                do {
                    try await read(url: url, state: &state, cutoff: cutoff)
                    state.size = size; state.modified = modified; state.inode = inode
                    current.files[url.path] = state
                } catch is CancellationError { throw CancellationError() }
                catch { report.unreadableCount += 1; continue }
            }
            if let id = state.sessionID, !sessionIDs.insert(id).inserted { continue }
            report.fileCount += 1
            for (key, tokens) in state.daily { report.daily[key, default: CodexTokenTotals()].add(tokens) }
            if let quota = state.quota, quota.updatedAt > (report.quota?.updatedAt ?? .distantPast) { report.quota = quota }
        }
        return report
    }

    private func loadCache(home: URL) {
        let timezone = TimeZone.current.identifier
        if cache?.home == home.path && cache?.timezone == timezone { return }
        let digest = SHA256.hash(data: Data(home.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.vedanth.boringnotch.octave/Codex", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("usage-\(digest).json")
        cacheURL = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Cache.self, from: data),
           saved.version == 1, saved.home == home.path, saved.timezone == timezone {
            cache = saved
        } else { cache = Cache(home: home.path, timezone: timezone) }
    }

    private func read(url: URL, state: inout FileState, cutoff: Date) async throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: state.offset)
        var line = Data()
        var lineLength: UInt64 = 0
        var oversized = false
        while let chunk = try file.read(upToCount: 128 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            var start = chunk.startIndex
            while start < chunk.endIndex {
                let newline = chunk[start...].firstIndex(of: 10)
                let end = newline ?? chunk.endIndex
                let count = end - start
                lineLength += UInt64(count)
                if lineLength > 8 * 1024 * 1024 { oversized = true; line.removeAll(keepingCapacity: false) }
                if !oversized { line.append(chunk[start..<end]) }
                if let newline {
                    if !oversized { consume(line, state: &state, cutoff: cutoff) }
                    state.offset += lineLength + 1
                    line.removeAll(keepingCapacity: true); lineLength = 0; oversized = false
                    start = newline + 1
                } else { break }
            }
            await Task.yield()
        }
        // An unfinished JSONL row remains unread, ready for the next append.
    }

    private func consume(_ line: Data, state: inout FileState, cutoff: Date) {
        guard line.range(of: tokenMarker) != nil || line.range(of: contextMarker) != nil || line.range(of: metaMarker) != nil,
              let raw = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = raw["payload"] as? [String: Any] else { return }
        switch raw["type"] as? String {
        case "session_meta":
            state.sessionID = payload["id"] as? String
            state.forked = payload["forked_from_id"] as? String != nil
            state.forkDate = (payload["timestamp"] as? String).flatMap(Self.parseDate)
        case "turn_context":
            if let model = payload["model"] as? String { state.model = model }
        case "event_msg":
            guard payload["type"] as? String == "token_count",
                  let timestamp = raw["timestamp"] as? String, let date = Self.parseDate(timestamp) else { return }
            if let limits = payload["rate_limits"] as? [String: Any],
               let quota = CodexQuotaSnapshot.parse(limits, at: date, local: true) { state.quota = quota }
            guard let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any] else { return }
            let cumulative = CodexTokenTotals(total)
            guard !state.hasPrevious || cumulative != state.previous else { return }
            let decreased = cumulative.input < state.previous.input || cumulative.output < state.previous.output
            let delta = decreased ? (info["last_token_usage"] as? [String: Any]).map(CodexTokenTotals.init) ?? cumulative
                                  : cumulative.delta(from: state.previous)
            state.previous = cumulative; state.hasPrevious = true
            guard delta.total > 0 else { return }
            if state.forked && !state.replayDone {
                // Original-timestamp history predates the fork. Rewritten history arrives
                // as a dense leading burst; defer its first sample until a second arrives.
                if let forkDate = state.forkDate, date < forkDate { return }
                if let lastDate = state.replayLastDate {
                    if date.timeIntervalSince(lastDate) >= 0 && date.timeIntervalSince(lastDate) <= 1 {
                        state.pendingTokens = nil; state.pendingModel = nil; state.replayBurst = true
                        state.replayLastDate = date; return
                    }
                    if !state.replayBurst, let pending = state.pendingTokens {
                        add(pending, model: state.pendingModel ?? state.model, date: lastDate, state: &state, cutoff: cutoff)
                    }
                    state.pendingTokens = nil; state.pendingModel = nil; state.replayDone = true
                } else {
                    state.replayLastDate = date; state.pendingTokens = delta; state.pendingModel = state.model; return
                }
            }
            add(delta, model: state.model, date: date, state: &state, cutoff: cutoff)
        default: break
        }
    }

    private func add(_ tokens: CodexTokenTotals, model: String, date: Date, state: inout FileState, cutoff: Date) {
        guard date >= cutoff else { return }
        state.daily["\(Self.dayKey(date))|\(model)", default: CodexTokenTotals()].add(tokens)
    }

    static func dayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
