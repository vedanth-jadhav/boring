import Foundation
import Observation

@Observable @MainActor
final class CodexUsageStore {
    static let shared = CodexUsageStore()
    var quota: CodexQuotaSnapshot?
    var models: [CodexModelUsage] = []
    var total = CodexTokenTotals()
    var estimate: Double?
    var unpricedModels = 0
    var period: CodexUsagePeriod = .today {
        didSet { rebuildSummary() }
    }
    var quotaError: String?
    var localError: String?
    var pricingError: String?
    var isRefreshing = false
    var isScanning = false
    var localUpdatedAt: Date?
    var pricingUpdatedAt: Date?
    var fileCount = 0
    var home: URL

    @ObservationIgnored private let scanner = CodexLogScanner()
    @ObservationIgnored private let client = CodexUsageClient()
    @ObservationIgnored private var daily: [String: CodexTokenTotals] = [:]
    @ObservationIgnored private var catalog: CodexRateCatalog?
    @ObservationIgnored private var identity: String?
    @ObservationIgnored private var recordedQuota: CodexQuotaSnapshot?
    @ObservationIgnored private var allowsRecordedQuota = false
    @ObservationIgnored private var lastQuotaAttempt = Date.distantPast
    @ObservationIgnored private var lastPricingAttempt = Date.distantPast
    @ObservationIgnored private var lastLocalAttempt = Date.distantPast
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var glanceTask: Task<Void, Never>?
    @ObservationIgnored private var quotaFailures = 0
    @ObservationIgnored private var credentialRevision: Date?

    private var quotaCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.vedanth.boringnotch.octave/Codex/allowance.json")
    }

    init(home: URL? = nil) {
        let custom = UserDefaults.standard.string(forKey: "codexUsageHome")
        let environment = ProcessInfo.processInfo.environment["CODEX_HOME"]
        self.home = home ?? (custom ?? environment).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    func monitor() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
        }
    }

    /// The glance needs allowance only; token scanning and pricing stay in the dashboard.
    func setGlanceMonitoring(enabled: Bool) {
        if enabled {
            guard glanceTask == nil else { return }
            glanceTask = Task { [weak self] in
                guard let self else { return }
                await self.monitorAllowance()
            }
        } else {
            glanceTask?.cancel()
            glanceTask = nil
        }
    }

    private func monitorAllowance() async {
        while !Task.isCancelled {
            let revision = try? home.appendingPathComponent("auth.json").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let changed = revision != credentialRevision
            credentialRevision = revision
            await refreshAllowance(force: changed)
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    func refreshAllowance(force: Bool = false) async {
        await refreshQuota(force: force)
        guard !Task.isCancelled else { return }
        if quota == nil || quota?.isLocal == true { await refreshLocal(force: false) }
    }

    func refresh(force: Bool = false) async {
        async let local: Void = refreshLocal(force: force)
        async let remote: Void = refreshQuota(force: force, includeResetCredits: true)
        async let pricing: Void = refreshPricing(force: force)
        _ = await (local, remote, pricing)
    }

    func selectHome(_ url: URL) {
        home = url.standardizedFileURL
        UserDefaults.standard.set(home.path, forKey: "codexUsageHome")
        generation += 1
        quota = nil; identity = nil; recordedQuota = nil; allowsRecordedQuota = false
        quotaError = nil; localError = nil
        daily = [:]; localUpdatedAt = nil; fileCount = 0
        lastQuotaAttempt = .distantPast; lastLocalAttempt = .distantPast
        quotaFailures = 0; credentialRevision = nil
        rebuildSummary()
    }

    private func refreshLocal(force: Bool) async {
        guard !isScanning, force || Date().timeIntervalSince(lastLocalAttempt) >= 12 else { rebuildSummary(); return }
        isScanning = true
        defer { isScanning = false }
        let version = generation
        do {
            let report = try await scanner.scan(home: home)
            try Task.checkCancellation()
            guard version == generation else { return }
            daily = report.daily; fileCount = report.fileCount
            localError = report.unreadableCount > 0 ? "Some session files couldn’t be read. Totals may be incomplete." : nil
            localUpdatedAt = Date(); lastLocalAttempt = Date()
            recordedQuota = report.quota
            if quota == nil, allowsRecordedQuota, let recorded = report.quota { quota = recorded }
            rebuildSummary()
        } catch is CancellationError {} catch {
            guard version == generation else { return }
            localError = "Couldn’t read your Codex sessions. Check the selected folder and refresh."
        }
    }

    private func refreshQuota(force: Bool, includeResetCredits: Bool = false) async {
        let interval = quotaFailures == 0 ? 5 : min(60, 5 * pow(2, Double(min(quotaFailures, 4))))
        guard !isRefreshing, force || Date().timeIntervalSince(lastQuotaAttempt) >= interval else { return }
        isRefreshing = true; lastQuotaAttempt = Date()
        defer { isRefreshing = false }
        let version = generation
        do {
            let credentials = try await client.credentials(home: home)
            guard version == generation else { return }
            if identity != nil, identity != credentials.identity { quota = nil; recordedQuota = nil }
            identity = credentials.identity
            allowsRecordedQuota = true
            if quota == nil,
               let data = try? Data(contentsOf: quotaCacheURL),
               let cached = try? JSONDecoder().decode(CodexCachedQuota.self, from: data),
               cached.identity == credentials.identity {
                quota = cached.snapshot
            }
            var snapshot = try await client.quota(credentials: credentials, includeResetCredits: includeResetCredits)
            let latest = try await client.credentials(home: home)
            try Task.checkCancellation()
            guard version == generation else { return }
            guard latest.identity == credentials.identity else { quota = nil; lastQuotaAttempt = .distantPast; return }
            if !includeResetCredits {
                snapshot.resetCredits = quota?.resetCredits ?? []
                snapshot.resetCount = snapshot.resetCount ?? quota?.resetCount
            }
            quota = snapshot; quotaError = nil; quotaFailures = 0
            if let data = try? JSONEncoder().encode(CodexCachedQuota(identity: credentials.identity, snapshot: snapshot)) {
                try? FileManager.default.createDirectory(at: quotaCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])
                try? data.write(to: quotaCacheURL, options: .atomic)
            }
        } catch is CancellationError { lastQuotaAttempt = .distantPast }
        catch {
            guard version == generation else { return }
            quotaFailures += 1
            if case CodexUsageClient.Failure.notSignedIn = error { quota = nil; identity = nil; allowsRecordedQuota = false }
            if case CodexUsageClient.Failure.apiKey = error { quota = nil; identity = nil; allowsRecordedQuota = false }
            if quota == nil, allowsRecordedQuota { quota = recordedQuota }
            quotaError = (error as? LocalizedError)?.errorDescription ?? "Couldn’t refresh Codex usage. Try again."
        }
    }

    private func refreshPricing(force: Bool) async {
        guard force || Date().timeIntervalSince(lastPricingAttempt) >= 3_600 else { return }
        lastPricingAttempt = Date()
        do {
            let result = try await client.pricing(force: force)
            try Task.checkCancellation()
            catalog = result; pricingUpdatedAt = result.updatedAt
            pricingError = Date().timeIntervalSince(result.updatedAt) > 86_400 ? "Saved rates · live pricing couldn’t refresh" : nil
            rebuildSummary()
        } catch is CancellationError { lastPricingAttempt = .distantPast }
        catch { pricingError = "Live pricing unavailable · view OpenAI pricing" }
    }

    private func rebuildSummary() {
        let start = CodexLogScanner.dayKey(period.start(at: Date()))
        var totals: [String: CodexTokenTotals] = [:]
        for (key, tokens) in daily {
            let parts = key.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, String(parts[0]) >= start else { continue }
            totals[String(parts[1]), default: CodexTokenTotals()].add(tokens)
        }
        models = totals.map { CodexModelUsage(id: $0.key, tokens: $0.value, rate: catalog?.rate(for: $0.key)) }
            .sorted { $0.tokens.total == $1.tokens.total ? $0.id < $1.id : $0.tokens.total > $1.tokens.total }
        total = CodexTokenTotals(); var cost = 0.0; unpricedModels = 0
        for model in models {
            total.add(model.tokens)
            if let estimate = model.estimate { cost += estimate } else { unpricedModels += 1 }
        }
        estimate = !models.isEmpty && unpricedModels == 0 ? cost : nil
    }
}
