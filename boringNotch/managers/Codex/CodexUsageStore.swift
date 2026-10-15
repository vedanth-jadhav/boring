import Foundation
import Observation

@Observable @MainActor
final class CodexUsageStore {
    static let shared = CodexUsageStore()
    var provider: AIUsageProvider = AIUsageProvider(rawValue: UserDefaults.standard.string(forKey: "aiUsageProvider") ?? "") ?? .codex {
        didSet {
            guard provider != oldValue else { return }
            UserDefaults.standard.set(provider.rawValue, forKey: "aiUsageProvider")
            clearAccountReading()
        }
    }
    var connectionMessages: [AIUsageProvider: String] = [:]
    var connecting: Set<AIUsageProvider> = []
    @ObservationIgnored private var loginTasks: [AIUsageProvider: Task<Void, Never>] = [:]
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
    @ObservationIgnored private var lastQuotaAttempt = Date.distantPast
    @ObservationIgnored private var lastPricingAttempt = Date.distantPast
    @ObservationIgnored private var lastLocalAttempt = Date.distantPast
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var glanceTask: Task<Void, Never>?
    @ObservationIgnored private var quotaFailures = 0

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
            await refreshAllowance()
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    func refreshAllowance(force: Bool = false) async {
        await refreshQuota(force: force)
        guard !Task.isCancelled else { return }

    }

    func refresh(force: Bool = false) async {
        async let local: Void = refreshLocal(force: force)
        async let remote: Void = refreshQuota(force: force)
        async let pricing: Void = refreshPricing(force: force)
        _ = await (local, remote, pricing)
    }

    func selectHome(_ url: URL) {
        home = url.standardizedFileURL
        UserDefaults.standard.set(home.path, forKey: "codexUsageHome")
        generation += 1
        quota = nil
        quotaError = nil; localError = nil
        daily = [:]; localUpdatedAt = nil; fileCount = 0
        lastQuotaAttempt = .distantPast; lastLocalAttempt = .distantPast
        quotaFailures = 0
        rebuildSummary()
    }

    private func refreshLocal(force: Bool) async {
        guard provider == .codex else { return }
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
            rebuildSummary()
        } catch is CancellationError {} catch {
            guard version == generation else { return }
            localError = "Couldn’t read your Codex sessions. Check the selected folder and refresh."
        }
    }

    func clearAccountReading() {
        generation += 1
        quota = nil; quotaError = nil; quotaFailures = 0
        lastQuotaAttempt = .distantPast
    }

    func loadConnectionStates() async {
        for account in AIUsageProvider.allCases where !connecting.contains(account) {
            connectionMessages[account] = await NativeAccountClient.shared.connected(account) ? "Connected" : "Not connected"
        }
    }

    func connect(_ provider: AIUsageProvider? = nil) {
        let target = provider ?? self.provider
        guard loginTasks[target] == nil else { return }
        if target == self.provider { clearAccountReading() }
        connecting.insert(target)
        connectionMessages[target] = "Opening sign-in…"
        loginTasks[target] = Task { [weak self] in
            guard let self else { return }
            defer { self.connecting.remove(target); self.loginTasks[target] = nil }
            do {
                let revision = await NativeAccountClient.shared.beginAuthorization(target)
                let token = try await NativeOAuthSignIn.signIn(target) { [weak self] in self?.connectionMessages[target] = $0 }
                try Task.checkCancellation()
                try await NativeAccountClient.shared.save(token, for: target, authorizationRevision: revision)
                self.connectionMessages[target] = "Connected"
                if self.provider == target {
                    self.clearAccountReading()
                    self.connecting.remove(target)
                    await self.refreshAllowance(force: true)
                }
            } catch is CancellationError {
                self.connectionMessages[target] = "Sign-in cancelled"
            } catch {
                self.connectionMessages[target] = error.localizedDescription
                if self.provider == target { self.quotaError = error.localizedDescription }
            }
        }
    }

    func cancelSignIn(_ provider: AIUsageProvider) { loginTasks[provider]?.cancel() }

    func disconnect(_ provider: AIUsageProvider) async {
        loginTasks[provider]?.cancel()
        if self.provider == provider { clearAccountReading() }
        do {
            try await NativeAccountClient.shared.disconnect(provider)
            connectionMessages[provider] = "Not connected"
        } catch { connectionMessages[provider] = "Couldn’t disconnect. Please try again." }
    }

    private func refreshQuota(force: Bool) async {
        let interval = provider == .antigravity ? 60.0 : quotaFailures == 0 ? 30 : min(120, 30 * pow(2, Double(min(quotaFailures, 2))))
        guard !isRefreshing, !connecting.contains(provider), force || Date().timeIntervalSince(lastQuotaAttempt) >= interval else { return }
        isRefreshing = true; lastQuotaAttempt = Date()
        defer { isRefreshing = false }
        let version = generation
        do {
            let snapshot = try await NativeAccountClient.shared.quota(provider)
            try Task.checkCancellation()
            guard version == generation else { lastQuotaAttempt = .distantPast; return }
            quota = snapshot; quotaError = nil; quotaFailures = 0
        } catch is CancellationError { lastQuotaAttempt = .distantPast }
        catch {
            guard version == generation else { lastQuotaAttempt = .distantPast; return }
            quotaFailures += 1
            if case AccountFailure.signIn = error { quota = nil; connectionMessages[provider] = "Sign-in needed" }
            quotaError = error.localizedDescription
        }
    }

    private func refreshPricing(force: Bool) async {
        guard provider == .codex else { return }
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
