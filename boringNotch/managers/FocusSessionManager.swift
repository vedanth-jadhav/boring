import AppKit
import Combine
import CaffeineEngine

@MainActor
final class FocusSessionManager: ObservableObject {
    static let shared = FocusSessionManager(feedback: FocusHaptics.action)
    static let persistenceKey = "focusSession.v1"

    @Published private(set) var session = FocusSessionSnapshot()
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBusy = false
    lazy var caffeine = CaffeineEngine()
    private var caffeineSubscription: AnyCancellable?
    private let usesCaffeineEngine: Bool
    let selection = FocusDurationSelection()
    var selectedMinutes: Int {
        get { selection.minutes }
        set { selection.minutes = newValue }
    }
    var selectedMode: FocusSessionMode {
        get { selection.mode }
        set { selection.mode = newValue }
    }

    private let defaults: UserDefaults
    private let power: FocusPowerManaging
    private let now: () -> Date
    private let feedback: @MainActor () -> Void
    private var expiryTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    var isActive: Bool { session.state != .idle }

    init(defaults: UserDefaults = .standard, power: FocusPowerManaging? = nil,
         now: @escaping () -> Date = Date.init, observeLifecycle: Bool = true,
         feedback: @escaping @MainActor () -> Void = {}) {
        self.usesCaffeineEngine = power == nil && observeLifecycle
        self.defaults = defaults
        self.power = power ?? CaffeineManager.shared
        self.now = now
        self.feedback = feedback
        restore()
        if observeLifecycle { installObservers() }
        if usesCaffeineEngine {
            isBusy = true
            caffeineSubscription = caffeine.objectWillChange.sink { [weak self] in
                Task { @MainActor in self?.syncCaffeine() }
            }
            Task { @MainActor in
                await caffeine.prepare()
                isBusy = false
                syncCaffeine(restoring: true)
            }
        }
    }

    @discardableResult
    func start() -> Bool {
        guard !isActive, !isBusy else { return false }
        if selectedMode == .caffeine, usesCaffeineEngine {
            beginCaffeine(seconds: TimeInterval(min(120, max(1, selectedMinutes)) * 60), resuming: false)
            return true
        }
        let duration = TimeInterval(min(120, max(1, selectedMinutes)) * 60)
        let deadline = now().addingTimeInterval(duration)
        if selectedMode == .caffeine, !power.acquire(owner: .focusSession, until: deadline) {
            errorMessage = "Couldn’t keep your Mac awake. Try starting again."
            return false
        }
        errorMessage = nil
        session = FocusSessionSnapshot(mode: selectedMode, state: .running, duration: duration, deadline: deadline)
        commit()
        feedback()
        return true
    }

    func pause() {
        guard session.state == .running, !isBusy else { return }
        if session.mode == .caffeine, usesCaffeineEngine {
            endCaffeine(pausing: true)
            return
        }
        let remaining = session.remaining(at: now())
        guard remaining > 0 else { expireIfNeeded(); return }
        power.release(owner: .focusSession)
        session.pausedRemaining = remaining
        session.deadline = nil
        session.state = .paused
        commit()
        feedback()
    }

    @discardableResult
    func resume() -> Bool {
        guard session.state == .paused, session.pausedRemaining > 0, !isBusy else { return false }
        if session.mode == .caffeine, usesCaffeineEngine {
            beginCaffeine(seconds: session.pausedRemaining, resuming: true)
            return true
        }
        let deadline = now().addingTimeInterval(session.pausedRemaining)
        if session.mode == .caffeine, !power.acquire(owner: .focusSession, until: deadline) {
            errorMessage = "Couldn’t keep your Mac awake. Try resuming again."
            return false
        }
        errorMessage = nil
        session.deadline = deadline
        session.pausedRemaining = 0
        session.state = .running
        commit()
        feedback()
        return true
    }

    func cancel() {
        guard isActive, !isBusy else { return }
        if session.mode == .caffeine, usesCaffeineEngine, session.state == .running {
            endCaffeine(pausing: false)
            return
        }
        finish()
        feedback()
    }

    func expireIfNeeded() {
        guard !isBusy, session.state == .running, session.remaining(at: now()) <= 0 else { return }
        if session.mode == .caffeine, usesCaffeineEngine {
            endCaffeine(pausing: false)
            return
        }
        finish()
        feedback()
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
            userInfo: [.announcement: "\(session.mode.title) complete", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func reconcileAfterWake() {
        expireIfNeeded()
        if !usesCaffeineEngine, session.state == .running, session.mode == .caffeine,
           !power.acquire(owner: .focusSession, until: session.deadline) {
            pause()
            errorMessage = "Caffeine paused because your Mac couldn’t be kept awake."
        }
        scheduleExpiry()
    }

    /// Keep the deadline for relaunch, but remove this process's power lease.
    func shutdown() {
        persist()
        expiryTimer?.invalidate()
        expiryTimer = nil
        power.release(owner: .focusSession)
        observers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        workspaceObservers.removeAll()
    }

    private func beginCaffeine(seconds: TimeInterval, resuming: Bool) {
        isBusy = true
        errorMessage = nil
        Task { @MainActor in
            let settings = CaffeineSettings.shared
            var allowed = await caffeine.isAuthorized()
            if !allowed { allowed = await caffeine.authorize() }
            guard allowed else {
                errorMessage = "Setup was cancelled. Start again when you’re ready."
                isBusy = false
                return
            }
            settings.authorized = true
            do { try settings.apply(to: caffeine) } catch {
                errorMessage = "Your choices couldn’t be saved. Try starting again."
                isBusy = false
                return
            }
            let started = await caffeine.start(seconds: seconds)
            if started, let deadline = caffeine.deadline {
                let duration = resuming ? session.duration : seconds
                session = FocusSessionSnapshot(mode: .caffeine, state: .running, duration: duration, deadline: deadline)
                commit()
                feedback()
            } else {
                errorMessage = "Caffeine couldn’t start. Open its settings and choose Restore, then try again."
            }
            isBusy = false
        }
    }

    private func endCaffeine(pausing: Bool) {
        isBusy = true
        let remaining = session.remaining(at: now())
        Task { @MainActor in
            if await caffeine.stop() {
                if pausing && remaining > 0 {
                    session.pausedRemaining = remaining
                    session.deadline = nil
                    session.state = .paused
                    commit()
                } else { finish() }
                feedback()
            } else {
                errorMessage = "Your Mac is still being restored. Keep the app open and choose Restore in Caffeine settings."
            }
            isBusy = false
        }
    }

    private func syncCaffeine(restoring: Bool = false) {
        guard usesCaffeineEngine, !isBusy else { return }
        if let deadline = caffeine.deadline, let startedAt = caffeine.startedAt {
            if restoring || !isActive {
                session = FocusSessionSnapshot(mode: .caffeine, state: .running,
                    duration: min(7200, max(60, deadline.timeIntervalSince(startedAt))), deadline: deadline)
                selectedMode = .caffeine
                selection.caffeineReady = true
                commit()
            }
        } else if session.mode == .caffeine, session.state == .running {
            finish()
        }
        if let message = caffeine.message { errorMessage = message }
        else if session.mode == .caffeine { errorMessage = nil }
    }

    func prepareToQuit() async -> Bool {
        guard usesCaffeineEngine else { return true }
        let ready = await caffeine.stop(forQuit: true)
        if ready, session.mode == .caffeine, session.state == .running { finish() }
        return ready
    }

    private func finish() {
        power.release(owner: .focusSession)
        expiryTimer?.invalidate()
        expiryTimer = nil
        session = FocusSessionSnapshot(mode: session.mode, duration: session.duration)
        errorMessage = nil
        persist()
    }

    private func commit() {
        persist()
        scheduleExpiry()
    }

    private func persist() {
        if isActive, let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: Self.persistenceKey)
        } else {
            defaults.removeObject(forKey: Self.persistenceKey)
        }
    }

    private func restore() {
        guard let data = defaults.data(forKey: Self.persistenceKey),
              let saved = try? JSONDecoder().decode(FocusSessionSnapshot.self, from: data),
              saved.isValid, saved.state != .idle,
              saved.state != .running || (saved.remaining(at: now()) > 0 && saved.remaining(at: now()) <= saved.duration) else {
            defaults.removeObject(forKey: Self.persistenceKey)
            return
        }
        session = saved
        selectedMinutes = Int(saved.duration / 60)
        selectedMode = saved.mode
        if saved.state == .running, saved.mode == .caffeine,
           (usesCaffeineEngine || !power.acquire(owner: .focusSession, until: saved.deadline)) {
            session.pausedRemaining = saved.remaining(at: now())
            session.deadline = nil
            session.state = .paused
            errorMessage = "Caffeine restored paused. Resume to keep your Mac awake."
            persist()
        }
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard session.state == .running, let deadline = session.deadline else { return }
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireIfNeeded() }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    private func installObservers() {
        for name in [NSApplication.didBecomeActiveNotification, Notification.Name("NSSystemClockDidChangeNotification")] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileAfterWake() }
            })
        }
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileAfterWake() }
            })
    }
}
