import AppKit
import Combine
import Defaults

@MainActor final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()
    enum Availability: Equatable { case disabled, starting, observing, fullDiskAccessRequired, unavailable, suspended }
    @Published private(set) var state = NotificationQueueState()
    @Published private(set) var availability: Availability = .disabled
    @Published private(set) var isPresented = false
    private let source: any NotificationSource
    private let suppressor: any NativeBannerSuppressing
    private let enabledProvider: @MainActor () -> Bool
    private let openApplication: @MainActor (MirroredNotification) async -> Bool
    private var tokens = Set<AnyCancellable>()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []
    private var pending: [MirroredNotification] = []
    private var batchTask: Task<Void, Never>?, dismissTask: Task<Void, Never>?
    private var suppressionTasks: [String: Task<Void, Never>] = [:]
    private var generation = 0
    private var held = false, suspended = false, starting = false
    var activeNotification: MirroredNotification? { state.notifications.first }
    var queuedNotifications: [MirroredNotification] { Array(state.notifications.dropFirst()) }
    private var enabled: Bool { enabledProvider() }
    init(source: (any NotificationSource)? = nil, suppressor: (any NativeBannerSuppressing)? = nil,
         enabled: @escaping @MainActor () -> Bool = { Defaults[.notificationLiveActivity] },
         openApplication: @escaping @MainActor (MirroredNotification) async -> Bool = NotificationApplicationOpener.open) {
        self.source = source ?? NotificationStoreSource()
        self.suppressor = suppressor ?? NativeNotificationSuppressor()
        self.enabledProvider = enabled; self.openApplication = openApplication
        self.source.events.receive(on: RunLoop.main).sink { [weak self] event in
            Task { @MainActor in self?.receive(event) }
        }.store(in: &tokens)
        for (name, suspend) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setSuspended(suspend) }
            })
        }
        for (name, suspend) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            lockObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setSuspended(suspend) }
            })
        }
        XPCHelperClient.shared.$helperAvailable.dropFirst().removeDuplicates().receive(on: RunLoop.main).sink { [weak self] available in
            Task { @MainActor in
                guard let self, self.enabled, !self.suspended else { return }
                if available { await self.start() } else { self.availability = .unavailable }
            }
        }.store(in: &tokens)
    }
    deinit {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        lockObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        batchTask?.cancel(); dismissTask?.cancel()
        suppressionTasks.values.forEach { $0.cancel() }
    }
    func start() async {
        guard enabled, !suspended, !starting, availability != .observing else { return }
        starting = true; defer { starting = false }
        let epoch = generation; availability = .starting
        await configureSource()
        guard epoch == generation, enabled, !suspended else { return }
        let success = await source.start()
        guard epoch == generation, enabled, !suspended else { source.stop(); return }
        if success { availability = .observing }
        else if availability == .starting { availability = .unavailable }
    }
    func stop() {
        generation += 1; source.stop()
        batchTask?.cancel(); batchTask = nil; pending.removeAll()
        dismissTask?.cancel(); dismissTask = nil
        suppressionTasks.values.forEach { $0.cancel() }; suppressionTasks.removeAll()
        if !enabled { state.reset(); isPresented = false }
        availability = .disabled
    }
    func setSuspended(_ value: Bool) {
        suspended = value
        if value { stop(); isPresented = false; availability = .suspended }
        else { Task { await start() } }
    }
    func updateFilter() {
        for item in state.notifications where !isAllowed(item) { state.remove(item.id) }
        if state.notifications.isEmpty { isPresented = false }
        Task { await configureSource() }
    }
    private func configureSource() async {
        var ignored = Defaults[.notificationBlockedApps]
        if let own = Bundle.main.bundleIdentifier { ignored.insert(own) }
        await source.configure(allowed: Defaults[.notificationAllowedApps], allApps: Defaults[.notificationsFromAllApps], ignored: ignored)
    }
    private func isAllowed(_ item: MirroredNotification) -> Bool {
        var ignored = Defaults[.notificationBlockedApps]
        if let own = Bundle.main.bundleIdentifier { ignored.insert(own) }
        return NotificationFilter(allApps: Defaults[.notificationsFromAllApps], allowed: Defaults[.notificationAllowedApps], ignored: ignored).allows(appName: item.appName, bundleID: item.bundleID)
    }
    func receive(_ event: NotificationSourceEvent) {
        guard enabled, !suspended, event.version == 2 else { return }
        switch event.kind {
        case .ready: availability = .observing
        case .unavailable: availability = event.failure == .fullDiskAccess ? .fullDiskAccessRequired : .unavailable
        case .upsert:
            guard let item = event.notification, isAllowed(item) else { return }
            pending.append(item)
            if batchTask == nil {
                batchTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(16))
                    guard !Task.isCancelled else { return }; self?.flush()
                }
            }
        }
    }
    private func flush() {
        batchTask = nil
        var next = state, arrivals: [MirroredNotification] = []
        for var item in pending {
            guard isAllowed(item) else { continue }
            if let app = NotificationApplicationOpener.application(for: item) {
                item = .init(id: item.id, appName: app.name, bundleID: app.bundleID, title: item.title, subtitle: item.subtitle, body: item.body, receivedAt: item.receivedAt, iconData: item.iconData)
            }
            let prior = next.notifications.first(where: { $0.id == item.id })
            next.upsert(item)
            let changed = prior.map { $0.body != item.body || $0.title != item.title || item.receivedAt > $0.receivedAt } ?? true
            if changed, next.notifications.contains(where: { $0.id == item.id }) { arrivals.append(item) }
        }
        pending.removeAll(); state = next
        if !arrivals.isEmpty { isPresented = true }
        for item in arrivals where Defaults[.notificationSuppressNativeBanners] {
            suppressionTasks[item.id]?.cancel()
            suppressionTasks[item.id] = Task { [weak self, suppressor] in
                for delay in [0, 80, 180, 350] {
                    if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                    guard !Task.isCancelled else { return }
                    if await suppressor.suppress(item) { break }
                }
                self?.suppressionTasks.removeValue(forKey: item.id)
            }
        }
        scheduleDismiss(after: 9)
    }
    func dismissActive(token: String? = nil) {
        guard let id = token ?? activeNotification?.id else { return }
        state.remove(id)
        if state.notifications.isEmpty { isPresented = false }
    }
    func showRecent() { isPresented = !state.notifications.isEmpty; scheduleDismiss(after: 9) }
    func holdActive() { held = true; dismissTask?.cancel(); dismissTask = nil }
    func resumeDismiss(after delay: TimeInterval = 3) { held = false; scheduleDismiss(after: delay) }
    private func scheduleDismiss(after delay: TimeInterval) {
        dismissTask?.cancel(); dismissTask = nil
        guard !held else { return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }; self.isPresented = false
        }
    }
    @discardableResult func open(_ item: MirroredNotification) async -> Bool {
        let opened = await openApplication(item)
        if opened { dismissActive(token: item.id) }
        return opened
    }
    nonisolated static func bundleIDCandidates(for notification: MirroredNotification, resolvedBundleID: String? = nil) -> [String] {
        var result: [String] = []
        for id in [notification.bundleID, resolvedBundleID].compactMap({ $0 }).map(normalizeBundleIdentifier) where !result.contains(id) { result.append(id) }
        return result
    }
}
