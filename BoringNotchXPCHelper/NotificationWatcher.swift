import Foundation
import Dispatch
import ApplicationServices

/// Captures semantic records from usernoted, never from Notification Center's
/// editor. SQLite, WAL observation and parsing stay on one worker queue.
final class NotificationWatcher {
    private let worker = DispatchQueue(label: "boring.notifications.store", qos: .utility)
    private let bannerEvents = ["com.apple.notificationcenterui", "com.apple.UserNotificationCenter"].map {
        NotificationBannerEventObserver(bundleIdentifier: $0)
    }
    private let earlySource = AXNotificationSource()
    private var deduplicator = NotificationCaptureDeduplicator()
    private var reader: NotificationStoreReader?
    private var watches: [DispatchSourceFileSystemObject] = []
    private var recovery: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var emit: ((NotificationSourceEvent) -> Void)?
    private var cursor: Int64 = 0
    private var snapshots: [String: MirroredNotification] = [:]
    private var wanted = false
    private var announced = false
    private var allApps = false
    private var allowed = Set<String>(), ignored = Set<String>()
    private let defaults: UserDefaults
    private let storeURL: URL?
    init(storeURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.storeURL = storeURL; self.defaults = defaults
    }
    private var checkpointKey: String { "notificationStoreCheckpoint.v2" }
    func start(onEvent: @escaping (NotificationSourceEvent) -> Void, completion: @escaping (Bool) -> Void) {
        worker.async { [self] in
            self.emit = onEvent; self.wanted = true
            self.bannerEvents.forEach { observer in observer.start { [weak self] element in
                guard let self else { return }
                self.worker.async { [self] in
                    self.earlySource.begin(element)
                    self.captureEarly(element)
                    self.schedule()
                    for delay in [0.04, 0.12, 0.3] {
                        self.worker.asyncAfter(deadline: .now() + delay) { [weak self] in self?.captureEarly(element); self?.schedule() }
                    }
                }
            }
            }
            let started = self.attach()
            if self.recovery == nil {
                let timer = DispatchSource.makeTimerSource(queue: self.worker)
                timer.schedule(deadline: .now() + 3, repeating: 3, leeway: .seconds(1))
                timer.setEventHandler { [weak self] in self?.recover() }
                timer.resume(); self.recovery = timer
            }
            completion(started)
        }
    }
    func stop() {
        worker.async { self.wanted = false; self.bannerEvents.forEach { $0.stop() }; self.detach(); self.recovery?.cancel(); self.recovery = nil; self.emit = nil }
    }
    func configureFilter(bundleIDs: Set<String>, allApps: Bool, ignored: Set<String>, completion: @escaping () -> Void) {
        worker.async { self.allowed = bundleIDs; self.allApps = allApps; self.ignored = ignored; completion() }
    }
    private func captureEarly(_ element: AXUIElement) {
        guard wanted, let item = earlySource.read(element),
              NotificationFilter(allApps: allApps, allowed: allowed, ignored: ignored).allows(appName: item.appName, bundleID: item.bundleID),
              let captured = deduplicator.ingest(item) else { return }
        emit?(.init(kind: .upsert, notification: captured))
    }
    private func attach() -> Bool {
        if reader != nil { return true }
        let reader = NotificationStoreReader(path: storeURL ?? NotificationStoreReader.locate())
        do {
            let maximum = try reader.maximumID()
            let saved = defaults.dictionary(forKey: checkpointKey)
            if saved?["store"] as? String == reader.identity, let previous = saved?["cursor"] as? Int64, previous <= maximum {
                cursor = previous
            } else { cursor = maximum }
            // Seed the pre-checkpoint records so a restart cannot replay them.
            let baseline = try reader.read(after: max(0, cursor - 128), through: cursor)
            snapshots = Dictionary(baseline.notifications.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            self.reader = reader; announced = true
            emit?(.init(kind: .ready))
            installWatches(reader.path)
            scan()
            return true
        } catch { report(error); return false }
    }
    private func detach() {
        pending?.cancel(); pending = nil
        for watch in watches { watch.cancel() }; watches.removeAll()
        reader = nil; announced = false
    }
    private func installWatches(_ database: URL) {
        for path in [database.deletingLastPathComponent(), database, URL(fileURLWithPath: database.path + "-wal")] {
            let descriptor = open(path.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete], queue: worker)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.schedule()
            }
            source.setCancelHandler { close(descriptor) }; source.resume(); watches.append(source)
        }
    }
    private func schedule() {
        guard pending == nil, wanted else { return }
        let task = DispatchWorkItem { [weak self] in self?.pending = nil; self?.scan() }
        pending = task; worker.asyncAfter(deadline: .now() + 0.016, execute: task)
    }
    private func recover() {
        guard wanted else { return }
        bannerEvents.forEach { $0.refresh() }
        if let reader {
            if !reader.isCurrent { detach(); _ = attach() }
            else { scan() }
        } else { _ = attach() }
    }
    private func scan() {
        guard wanted, let reader else { return }
        do {
            if !reader.isCurrent { detach(); _ = attach(); return }
            if watches.count < 3, FileManager.default.fileExists(atPath: reader.path.path + "-wal") {
                for watch in watches { watch.cancel() }; watches.removeAll(); installWatches(reader.path)
            }
            // A request can update an existing record. Rescan only the bounded
            // recent tail, compare semantic snapshots, and never scan all history.
            let lowerBound = max(0, cursor - 64)
            let batch = try reader.read(after: lowerBound)
            // Rec IDs may reset if Notification Center replaces its store.
            if batch.cursor == cursor, try reader.maximumID() < cursor { detach(); _ = attach(); return }
            cursor = batch.cursor
            defaults.set(["store": batch.storeIdentity, "cursor": cursor], forKey: checkpointKey)
            if !announced { announced = true; emit?(.init(kind: .ready)) }
            let filter = NotificationFilter(allApps: allApps, allowed: allowed, ignored: ignored)
            let previousSnapshots = snapshots
            snapshots = Dictionary(batch.notifications.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            for item in batch.notifications where filter.allows(appName: item.appName, bundleID: item.bundleID) {
                guard previousSnapshots[item.id] != item else { continue }
                // Never replay old records when waking or after a restart.
                guard item.receivedAt > Date().addingTimeInterval(-120), item.receivedAt < Date().addingTimeInterval(10) else { continue }
                if let captured = deduplicator.ingest(item) { emit?(.init(kind: .upsert, notification: captured)) }
            }
            if batch.cursor < (try reader.maximumID()) { schedule() }
        } catch { detach(); report(error) }
    }
    private func report(_ error: Error) {
        let reason: NotificationSourceEvent.Failure
        switch error {
        case ProtectedStoreError.permission: reason = .fullDiskAccess
        case ProtectedStoreError.schema: reason = .unsupportedSchema
        case ProtectedStoreError.missing: reason = .missingStore
        default: reason = .disconnected
        }
        emit?(.init(kind: .unavailable, failure: reason))
    }
    #if DEBUG
    func diagnostics(completion: @escaping ([String: String]) -> Void) {
        worker.async { completion(["source": "usernoted-readonly", "storeOpen": String(self.reader != nil), "fileWatches": String(self.watches.count), "cursor": String(self.cursor)]) }
    }
    #endif
}
