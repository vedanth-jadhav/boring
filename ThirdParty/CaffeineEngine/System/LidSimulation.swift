import Foundation

/// Whether the file trigger behind scripts/simulate-lid.sh is compiled into
/// this build. It is in debug builds (`swift build`, `swift test`) and in
/// release builds made with `BORING_CAFFEINE_LID_SIMULATION=1 ./scripts/install.sh`,
/// which passes `-Xswiftc -DBORING_CAFFEINE_LID_SIMULATION`. A normal release
/// build has no watcher at all: nothing in the app reads the trigger file,
/// so a file written to the support directory cannot replay the lid-close
/// actions (darken, mute, freeze, pause Docker) during a session. A build
/// that has it says so in the log at launch, in the status menu and in
/// Settings.
enum LidSimulationBuild {
    static let isCompiledIn: Bool = {
        #if DEBUG || BORING_CAFFEINE_LID_SIMULATION
        return true
        #else
        return false
        #endif
    }()

    /// The watcher for `AppServices`, or nil when it is compiled out.
    @MainActor
    static func makeWatcher() -> (any LidSimulating)? {
        #if DEBUG || BORING_CAFFEINE_LID_SIMULATION
        return LidSimulation()
        #else
        return nil
        #endif
    }

    /// One line for the log, the status menu and Settings. Every use is
    /// behind `isCompiledIn`, but whether the text is left out of a plain
    /// release binary then depends on what the optimizer inlines, and
    /// scripts/check-lid-simulation-gate.sh fails on any copy. So the text
    /// is compiled in only with the watcher.
    #if DEBUG || BORING_CAFFEINE_LID_SIMULATION
    static let marker = "Lid simulation build: scripts/simulate-lid.sh is honoured during sessions"
    #else
    static let marker = ""
    #endif
}

/// What `AppServices` needs from the watcher, so a test can inject a fake
/// and prove the wiring is never started when the build flag is off.
@MainActor
protocol LidSimulating: AnyObject {
    /// Called on the main actor with `true` for closed.
    var onEvent: ((Bool) -> Void)? { get set }
    func start(directory: URL, file: URL)
    func stop()
}

#if DEBUG || BORING_CAFFEINE_LID_SIMULATION
/// File trigger for the lid-close action path, for release validation on a
/// machine whose lid stays open (scripts/simulate-lid.sh). Watches the
/// support directory; when the trigger file appears it is read, deleted
/// and delivered as a lid event. Same trust boundary as config.json: only
/// this user can write the directory. Only active while AppServices runs,
/// that is while a session is active, and only in builds that compile it
/// in (`LidSimulationBuild`).
///
/// The hardware reading (`LidObserver.readClamshellState`, used by
/// `refreshInstant` and reconcile) still reflects the real lid; this only
/// drives the close/open actions.
@MainActor
final class LidSimulation: LidSimulating {
    /// Called on the main actor with `true` for closed.
    var onEvent: ((Bool) -> Void)?

    private var source: (any DispatchSourceFileSystemObject)?
    private var file: URL?

    init() {}

    func start(directory: URL, file: URL) {
        guard source == nil else { return }
        self.file = file
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            Log.error("lid simulation: cannot watch \(directory.path): \(String(cString: strerror(errno)))")
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler { [weak self] in
            Task { @MainActor in self?.consume() }
        }
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
        // A trigger left over from before the session started is stale
        // (scripts/simulate-lid.sh says so): consumed and ignored, never
        // acted on, so an old "closed" cannot darken and freeze a session
        // that just started.
        while let text = claim() {
            Log.info("lid simulation: ignored stale trigger \"\(text)\"")
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        file = nil
    }

    /// Delivers every trigger on disk. The watcher calls this on each
    /// directory write; internal so tests can drive it without the watcher.
    /// Directory events coalesce, so a "closed" and an "open" written back
    /// to back can arrive as one event: keep claiming until the path is
    /// empty, so the pair is never cut to its first half.
    func consume() {
        while let text = claim() {
            switch text {
            case "closed":
                Log.info("lid SIMULATED closed (file trigger)")
                onEvent?(true)
            case "open":
                Log.info("lid SIMULATED open (file trigger)")
                onEvent?(false)
            case let other:
                Log.error("lid simulation: ignoring trigger \"\(other)\" (expected closed or open)")
            }
        }
    }

    // MARK: Private

    /// Claims the trigger before reading it: `rename(2)` to a per-process
    /// path is atomic, so two readers cannot both act on one write, and it
    /// replaces a claim file a crash left behind. ENOENT means there is no
    /// trigger (or another reader claimed it first). The claimed file is
    /// read and unlinked. nil when nothing was claimed.
    private func claim() -> String? {
        guard let file else { return nil }
        let claimed = file.appendingPathExtension("claimed.\(getpid())")
        guard rename(file.path, claimed.path) == 0 else {
            let code = errno
            if code != ENOENT {
                Log.error("lid simulation: cannot claim \(file.path): \(String(cString: strerror(code)))")
            }
            return nil
        }
        defer { try? FileManager.default.removeItem(at: claimed) }
        let text = (try? String(contentsOf: claimed, encoding: .utf8)) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
