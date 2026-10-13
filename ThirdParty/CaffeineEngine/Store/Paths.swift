import Foundation

/// Every on-disk location Caffeine uses. The whole tree can be relocated with
/// the `BORING_CAFFEINE_HOME` environment variable (tests, and `backstop.sh` honours
/// the same variable with the same layout).
///
/// Default layout:
///   ~/Applications/Caffeine.app/Contents/Resources/backstop.sh
///   ~/Library/Application Support/Boring Notch/Caffeine/{session.json,state.json,config.json,unfinished-command.json}
///   ~/Library/Logs/Boring Notch/Caffeine/{boring-caffeine.log,handoffs.log}
///   ~/Library/LaunchAgents/local.vedanth.boringnotch.caffeine.backstop.plist
///
/// With BORING_CAFFEINE_HOME=/x:
///   /x/Caffeine.app/Contents/Resources/backstop.sh
///   /x/{session.json,state.json,config.json,unfinished-command.json}
///   /x/Logs/{boring-caffeine.log,handoffs.log}
///   /x/LaunchAgents/local.vedanth.boringnotch.caffeine.backstop.plist
struct Paths: Sendable, Equatable {
    static let environmentKey = "BORING_CAFFEINE_HOME"
    static let backstopLabel = "local.vedanth.boringnotch.caffeine.backstop"
    static let bundleIdentifier = "local.vedanth.boringnotch.octave"

    let appSupport: URL
    let logs: URL
    let launchAgents: URL
    /// Where install.sh puts the app bundle. backstop.sh is sealed inside it.
    let appBundle: URL

    init(appSupport: URL, logs: URL, launchAgents: URL, appBundle: URL) {
        self.appSupport = appSupport
        self.logs = logs
        self.launchAgents = launchAgents
        self.appBundle = appBundle
    }

    /// Relocated layout rooted at one directory (used for BORING_CAFFEINE_HOME).
    init(root: URL) {
        self.init(
            appSupport: root,
            logs: root.appendingPathComponent("Logs", isDirectory: true),
            launchAgents: root.appendingPathComponent("LaunchAgents", isDirectory: true),
            appBundle: root.appendingPathComponent("Caffeine.app", isDirectory: true)
        )
    }

    /// The standard per-user layout under ~/Library.
    static var standard: Paths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library", isDirectory: true)
        return Paths(
            appSupport: library.appendingPathComponent("Application Support/Boring Notch/Caffeine", isDirectory: true),
            logs: library.appendingPathComponent("Logs/Boring Notch/Caffeine", isDirectory: true),
            launchAgents: library.appendingPathComponent("LaunchAgents", isDirectory: true),
            appBundle: Bundle.main.bundleURL
        )
    }

    /// `BORING_CAFFEINE_HOME` if set, else `standard`.
    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        if let root = env[environmentKey], !root.isEmpty {
            return Paths(root: URL(fileURLWithPath: root, isDirectory: true))
        }
        return .standard
    }

    var sessionFile: URL { appSupport.appendingPathComponent("session.json") }
    /// Where an unreadable session.json goes: this prefix, a UTC stamp
    /// (yyyyMMddTHHmmssZ) and, if that name is taken, -1, -2, ... The same
    /// shape is produced by backstop.sh and removed by `uninstall.sh --purge`.
    static let unreadableSessionPrefix = "session.json.unreadable-"
    var stateFile: URL { appSupport.appendingPathComponent("state.json") }
    var configFile: URL { appSupport.appendingPathComponent("config.json") }
    /// scripts/backstop.sh as install.sh seals it into a bundle, under
    /// Contents/Resources, before the bundle is signed. The LaunchAgent
    /// verifies the bundle's signature before running it (LaunchdBackstop).
    static func backstopScript(inBundle bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Resources/backstop.sh")
    }
    /// The sealed backstop.sh of the installed bundle.
    var backstopScript: URL { Self.backstopScript(inBundle: appBundle) }
    /// flock(2) file shared with backstop.sh (`lockf -k` on the same path).
    /// Created once, never unlinked, so both sides lock the same inode.
    var recoveryLock: URL { appSupport.appendingPathComponent(".recovery.lock") }
    /// The `sudo pmset` left running that holds the recovery lock, written
    /// while it runs so a relaunch after a crash can name it. Removed when
    /// it exits, and by the next transaction that takes the lock.
    var unfinishedCommandFile: URL { appSupport.appendingPathComponent("unfinished-command.json") }
    /// Written by scripts/simulate-lid.sh ("closed" or "open") to drive the
    /// lid-close action path without touching the hinge. See LidSimulation.
    var simulateLidFile: URL { appSupport.appendingPathComponent("simulate-lid") }

    /// Both logs are owner-only and rotate to `<name>.1` past
    /// `OwnerOnly.maxLogBytes`; uninstall.sh --purge removes the `.1` too.
    var logFile: URL { logs.appendingPathComponent("boring-caffeine.log") }
    var handoffsLog: URL { logs.appendingPathComponent("handoffs.log") }

    var backstopPlist: URL { launchAgents.appendingPathComponent("\(Paths.backstopLabel).plist") }

    /// Create every directory Caffeine writes into. Its own two are made
    /// 0700 (an existing one is tightened); the LaunchAgents directory is
    /// shared with every other login agent, so it is only created.
    func createDirectories() throws {
        if let problem = try OwnerOnly.createDirectory(appSupport) { OwnerOnly.reportOnce(problem) }
        if let problem = try OwnerOnly.createDirectory(logs) { OwnerOnly.reportOnce(problem) }
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
    }
}
