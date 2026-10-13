import AppKit
import Foundation

/// Spec section 5: Chromium browsers throttle occluded windows unless
/// launched with both flags. Detect, and relaunch with them on request.
enum ChromiumFlags {
    static let occluded = "--disable-backgrounding-occluded-windows"
    static let renderer = "--disable-renderer-backgrounding"
    static let required = [occluded, renderer]

    static let knownBrowsers: [String] = [
        "com.google.Chrome",
        "org.chromium.Chromium",
        "company.thebrowser.Browser",
    ]

    /// Known Chromium ids plus any agent-list id mentioning chrome/chromium.
    static func chromiumBundleIds(config: Config) -> [String] {
        var ids = knownBrowsers
        for id in config.agentList {
            let l = id.lowercased()
            if (l.contains("chrome") || l.contains("chromium")), !ids.contains(id) {
                ids.append(id)
            }
        }
        return ids
    }

    /// Splits a `ps -o args=` line into arguments, honouring single and
    /// double quotes and backslash escapes, so a flag that only appears
    /// inside another argument's quoted value is not counted.
    static func tokenize(_ args: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inSingle = false, inDouble = false, escaped = false, hasToken = false
        for ch in args {
            if escaped {
                current.append(ch)
                escaped = false
                hasToken = true
                continue
            }
            switch ch {
            case "\\" where !inSingle:
                escaped = true
            case "'" where !inDouble:
                inSingle.toggle()
                hasToken = true
            case "\"" where !inSingle:
                inDouble.toggle()
                hasToken = true
            case " ", "\t", "\n":
                if inSingle || inDouble {
                    current.append(ch)
                } else if hasToken {
                    out.append(current)
                    current = ""
                    hasToken = false
                }
            default:
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken { out.append(current) }
        return out
    }

    /// True when both required flags are present as their own arguments.
    static func hasBothFlags(args: String) -> Bool {
        let tokens = Set(tokenize(args).map { $0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? $0 })
        return required.allSatisfy { tokens.contains($0) }
    }

    /// Arguments worth carrying over on relaunch so the same profile opens.
    static func preservedArgs(args: String) -> [String] {
        tokenize(args).dropFirst().filter {
            $0.hasPrefix("--user-data-dir=") || $0.hasPrefix("--profile-directory=")
        }
    }
}

struct BrowserStatus: Sendable, Equatable {
    let bundleId: String
    let name: String
    let pid: Int32
    let unthrottled: Bool
}

/// A browser the menu offers to relaunch: the bundle id the relaunch acts
/// on and the name the prompt and any notification show. The menu item
/// keeps both as they were when the menu was built, so a scan that
/// replaces the browser list while the confirmation is up cannot change or
/// drop the browser the user confirmed.
struct ThrottledBrowser: Sendable, Hashable {
    let bundleId: String
    let name: String
}

/// Waits for AppKit termination notifications with one timeout event. This
/// keeps relaunch event-driven instead of waking every few hundred ms.
@MainActor
private final class ApplicationTerminationWaiter {
    private let applications: [NSRunningApplication]
    private var pending: Set<Int32> = []
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var continuation: CheckedContinuation<Bool, Never>?

    init(applications: [NSRunningApplication]) {
        self.applications = applications
    }

    func terminateAndWait(timeout: TimeInterval) async -> Bool {
        pending = Set(applications.lazy.filter { !$0.isTerminated }.map(\.processIdentifier))
        guard !pending.isEmpty else { return true }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let center = NSWorkspace.shared.notificationCenter
            observer = center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                Task { @MainActor [weak self] in self?.applicationTerminated(pid) }
            }

            let timeoutTimer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.finish(allTerminated: false) }
            }
            RunLoop.main.add(timeoutTimer, forMode: .common)
            timer = timeoutTimer

            for application in applications where !application.isTerminated {
                application.terminate()
            }
        }
    }

    private func applicationTerminated(_ pid: Int32) {
        pending.remove(pid)
        if pending.isEmpty { finish(allTerminated: true) }
    }

    private func finish(allTerminated: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.invalidate()
        timer = nil
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        continuation.resume(returning: allTerminated)
    }
}

/// One running copy of a browser, as the running list showed it. A quit
/// goes to `process`, never to a fresh lookup of `pid`: by the time the
/// quit goes out the pid may belong to another app, while the object
/// stands for this one process and quits nothing once it has exited.
struct BrowserInstance {
    let pid: Int32
    /// The workspace's `NSRunningApplication` in the app; the fake's own
    /// object in tests.
    let process: AnyObject
    /// The kernel's start time for `pid` when the list was read, which a
    /// later process given the same pid cannot share; nil when it could
    /// not be read, and then nothing read by pid can be tied to this
    /// process.
    let identity: ProcessIdentity?
}

/// The process side of a relaunch: which instances of a browser are
/// running, quitting them, launching one. The app's implementation is
/// NSWorkspace and `open -b`; tests inject a fake, so nothing real is quit.
@MainActor
protocol BrowserProcessControlling: AnyObject {
    /// Every running application with this bundle id.
    func runningInstances(bundleId: String) -> [BrowserInstance]
    /// Whether `instance` is still the process the list showed: it has not
    /// exited, and its pid has not gone to a later process. False when
    /// that cannot be confirmed.
    func isRunning(_ instance: BrowserInstance) -> Bool
    /// Ask each instance to quit and wait: true once all have quit, false
    /// when `timeout` passes first.
    func terminateAndWait(_ instances: [BrowserInstance], timeout: TimeInterval) async -> Bool
    /// `open -b <bundleId> --args <arguments>`; throws when `open` fails.
    func launch(bundleId: String, arguments: [String]) async throws
    /// Wait for an application with this bundle id to appear in the running
    /// list: true as soon as one does, false when `timeout` passes first.
    /// Throws CancellationError, and nothing else, when the task is
    /// cancelled during the wait.
    func waitUntilRunning(bundleId: String, timeout: TimeInterval) async throws -> Bool
}

struct BrowserProcessError: Error, LocalizedError, Equatable {
    let detail: String
    var errorDescription: String? { detail }
}

@MainActor
final class WorkspaceBrowserProcesses: BrowserProcessControlling {
    func runningInstances(bundleId: String) -> [BrowserInstance] {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleId && !$0.isTerminated }
            .map { BrowserInstance(pid: $0.processIdentifier, process: $0, identity: Self.identity(of: $0.processIdentifier)) }
    }

    /// `isTerminated` changes when the workspace's notification arrives,
    /// which can trail the exit; the kernel's start time for the pid says
    /// at once whether it is still this process. Without a recorded start
    /// time, or with one that cannot be read now, nothing confirms it, so
    /// the answer is no.
    func isRunning(_ instance: BrowserInstance) -> Bool {
        guard let application = instance.process as? NSRunningApplication else { return false }
        return Self.isRunning(terminated: application.isTerminated, recorded: instance.identity, pid: instance.pid)
    }

    /// The check itself, apart from the application object, so a test can
    /// run it on the test process's own pid, which stays alive throughout.
    static func isRunning(terminated: Bool, recorded: ProcessIdentity?, pid: Int32) -> Bool {
        guard !terminated, let recorded else { return false }
        return identity(of: pid) == recorded
    }

    /// Quits the application objects the list returned, as found. One whose
    /// process has exited since is skipped, and nothing is looked up again
    /// by pid.
    func terminateAndWait(_ instances: [BrowserInstance], timeout: TimeInterval) async -> Bool {
        let applications = instances.compactMap { $0.process as? NSRunningApplication }
        return await ApplicationTerminationWaiter(applications: applications).terminateAndWait(timeout: timeout)
    }

    func launch(bundleId: String, arguments: [String]) async throws {
        let r = try await Shell.run("/usr/bin/open", ["-b", bundleId, "--args"] + arguments, timeout: 15)
        guard r.succeeded else {
            let stderr = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BrowserProcessError(detail: stderr.isEmpty ? "open exited with status \(r.status)" : stderr)
        }
    }

    func waitUntilRunning(bundleId: String, timeout: TimeInterval) async throws -> Bool {
        try await Self.poll(timeout: timeout) { !runningInstances(bundleId: bundleId).isEmpty }
    }

    /// Check `condition` every `interval` until it holds (true) or
    /// `timeout` has been slept through (false). The wait is counted in
    /// sleeps, so `sleep` is the only clock, and tests pass one they
    /// control. In a cancelled task `Task.sleep` throws at once, and the
    /// error is passed on: ignoring it would turn this loop into a spin on
    /// the main actor.
    static func poll(
        timeout: TimeInterval,
        every interval: Duration = .milliseconds(250),
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        until condition: () -> Bool
    ) async throws -> Bool {
        let sleeps = interval > .zero ? Int((.seconds(timeout) / interval).rounded(.up)) : 0
        for _ in 0..<sleeps {
            if condition() { return true }
            try await sleep(interval)
        }
        return condition()
    }

    private static func identity(of pid: Int32) -> ProcessIdentity? {
        guard case let .present(state) = SignalProcessControl.kernelState(pid: pid) else { return nil }
        return state.identity
    }
}

/// What "Relaunch <browser> unthrottled" did. Anything but `.relaunched`
/// and `.cancelled` is reported to the user in a notification; the
/// browser was quit only in `.launchFailed`, `.didNotStart` and
/// `.cancelled`.
enum RelaunchOutcome: Equatable, Sendable {
    /// Every instance quit, `open` returned 0, and an instance was running
    /// within `startTimeout`.
    case relaunched
    /// No instance was running; nothing to quit.
    case notRunning
    /// The main process's arguments could not be read, so the profile
    /// could not have been carried over. Nothing was quit.
    case argumentsUnreadable(String)
    /// An instance was still running after the wait. Nothing was launched:
    /// `open` would have put a second copy beside it.
    case stillRunning
    /// Every instance quit, then `open` failed. The browser is not running.
    case launchFailed(String)
    /// Every instance quit and `open` returned 0, but no instance was
    /// running `startTimeout` later. The browser is not running.
    case didNotStart
    /// Every instance quit and `open` returned 0, then the task was
    /// cancelled during the start wait because the session ended. Not
    /// reported: the user ended the session, and whether the browser came
    /// up is not known.
    case cancelled

    /// The notification body, naming the browser; nil when the relaunch
    /// happened.
    func explanation(browser name: String) -> String? {
        switch self {
        case .relaunched, .cancelled:
            nil
        case .notRunning:
            "\(name) is not running. Nothing was quit or relaunched."
        case let .argumentsUnreadable(detail):
            "Could not read \(name)'s profile arguments (\(detail)), so a relaunch could have opened the wrong profile. \(name) was not quit."
        case .stillRunning:
            "\(name) did not quit within \(Int(BrowserThrottle.quitTimeout)) s, so nothing was relaunched. It may still quit later. If it does, open it again yourself."
        case let .launchFailed(detail):
            "\(name) quit but could not be relaunched: \(detail). Open it yourself."
        case .didNotStart:
            "\(name) quit and was asked to open again, but it was not running after \(Int(BrowserThrottle.startTimeout)) s. Open it yourself."
        }
    }
}

@MainActor
final class BrowserThrottle {
    typealias ArgsReader = @Sendable (_ pid: Int32) async throws -> String

    /// How long a browser gets to quit before the relaunch gives up.
    nonisolated static let quitTimeout: TimeInterval = 10
    /// How long a relaunched browser gets to show up in the running list
    /// before the relaunch is reported as failed.
    nonisolated static let startTimeout: TimeInterval = 5

    private(set) var statuses: [BrowserStatus] = []
    /// Running Chromium browsers missing either flag.
    var throttledBrowsers: [ThrottledBrowser] {
        statuses.filter { !$0.unthrottled }.map { ThrottledBrowser(bundleId: $0.bundleId, name: $0.name) }
    }

    private let readArgs: ArgsReader
    private let processes: any BrowserProcessControlling

    init(readArgs: ArgsReader? = nil, processes: (any BrowserProcessControlling)? = nil) {
        self.readArgs = readArgs ?? BrowserThrottle.psArgs
        self.processes = processes ?? WorkspaceBrowserProcesses()
    }

    /// Inspect every running Chromium browser's main process.
    @discardableResult
    func scan(config: Config) async -> [BrowserStatus] {
        let ids = ChromiumFlags.chromiumBundleIds(config: config)
        var out: [BrowserStatus] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, ids.contains(id) else { continue }
            let pid = app.processIdentifier
            let name = app.localizedName ?? id
            do {
                let args = try await readArgs(pid)
                out.append(BrowserStatus(bundleId: id, name: name, pid: pid, unthrottled: ChromiumFlags.hasBothFlags(args: args)))
            } catch {
                Log.error("browser throttle: could not read args of \(name): \(error.localizedDescription)")
            }
        }
        statuses = out
        if !throttledBrowsers.isEmpty {
            Log.info("throttled browsers: \(throttledBrowsers.map(\.name).joined(separator: ", "))")
        }
        return out
    }

    /// Quit the browser, wait up to `quitTimeout` for every instance to
    /// exit, and only then launch it with both flags and the profile
    /// arguments it had. The arguments are read first: a browser whose
    /// arguments cannot be read is not quit, since a relaunch without them
    /// could open another profile. `ps` is given a pid, so the read counts
    /// only if the kernel's start time for that pid was read before it and
    /// matches after it; a main process that exits during the read, or
    /// whose start time cannot be read, counts as unreadable too, since
    /// the pid may have named another process. The quit goes to the
    /// instances the list returned, not to their pids. After the wait the
    /// running list is read again, and an instance still there (the waiter
    /// timed out, or one appeared meanwhile) means nothing is launched.
    /// `open` returning 0 is not the end either: the running list is
    /// polled for up to `startTimeout`, and a browser that has not appeared
    /// by then is reported, so the user is not left without a browser and
    /// without a word.
    func relaunchUnthrottled(bundleId: String) async -> RelaunchOutcome {
        let instances = processes.runningInstances(bundleId: bundleId)
        guard let main = instances.first else {
            Log.info("relaunch: \(bundleId) is not running")
            return .notRunning
        }
        let extra: [String]
        do {
            guard main.identity != nil else {
                throw BrowserProcessError(detail: "the start time of pid \(main.pid) could not be read to check them")
            }
            let args = try await readArgs(main.pid)
            guard !args.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BrowserProcessError(detail: "ps printed nothing for pid \(main.pid)")
            }
            guard processes.isRunning(main) else {
                throw BrowserProcessError(detail: "pid \(main.pid) exited while they were read, or could not be checked")
            }
            extra = ChromiumFlags.preservedArgs(args: args)
        } catch {
            Log.error("relaunch: could not read args of \(bundleId) (pid \(main.pid)): \(error.localizedDescription); not quitting")
            return .argumentsUnreadable(error.localizedDescription)
        }
        let quit = await processes.terminateAndWait(instances, timeout: Self.quitTimeout)
        let remaining = processes.runningInstances(bundleId: bundleId).map(\.pid)
        guard quit, remaining.isEmpty else {
            Log.error("relaunch: \(bundleId) still running after \(Int(Self.quitTimeout)) s (pids \(remaining)); not launching")
            return .stillRunning
        }
        do {
            try await processes.launch(bundleId: bundleId, arguments: ChromiumFlags.required + extra)
        } catch {
            Log.error("open -b \(bundleId) failed: \(error.localizedDescription)")
            return .launchFailed(error.localizedDescription)
        }
        let started: Bool
        do {
            started = try await processes.waitUntilRunning(bundleId: bundleId, timeout: Self.startTimeout)
        } catch {
            Log.info("relaunch: start check for \(bundleId) cancelled after open returned; not reporting")
            return .cancelled
        }
        guard started else {
            Log.error("relaunch: \(bundleId) not running \(Int(Self.startTimeout)) s after open returned")
            return .didNotStart
        }
        Log.info("relaunched \(bundleId) unthrottled")
        return .relaunched
    }

    static let psArgs: ArgsReader = { pid in
        let r = try await Shell.run("/bin/ps", ["-o", "args=", "-p", String(pid)], timeout: 5)
        return r.stdout
    }
}
