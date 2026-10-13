import AppKit
import Combine
import Darwin
import Observation

/// The host owns presentation; the vendored engine owns journaling and recovery.
@MainActor
public final class CaffeineEngine: ObservableObject {
    @Published public private(set) var deadline: Date?
    @Published public private(set) var startedAt: Date?
    @Published public private(set) var needsRecovery = false
    @Published public private(set) var message: String?
    @Published public private(set) var pausedAppCount = 0
    @Published public private(set) var lidClosed = false
    private let manager: SessionManager
    private var prepared = false

    public init() {
        manager = SessionManager.live()
        observe()
    }

    init(manager: SessionManager) {
        self.manager = manager
        observe()
    }

    public var keptAppIDs: Set<String> { Set(manager.config.agentList) }

    public func prepare() async {
        guard !prepared else { return }
        prepared = true
        await manager.reconcile()
        publish()
    }

    public func configure(keepApps: [String], pauseApps: [String], lowPower: Bool,
                          mute: Bool, batteryLimit: Int, protectFromHeat: Bool) throws {
        var config = manager.config
        config.agentList = keepApps
        config.freezeList = pauseApps
        config.freezeAllApps = false
        config.dockerRule = false
        config.disableAppNapForAgents = false
        config.lowPowerOnLidClose = lowPower
        config.lowPowerFloor = lowPower ? 40 : 0
        config.endFloor = min(30, max(10, batteryLimit))
        config.thermalRules = protectFromHeat
        config.muteOnLidClose = mute
        config.darkenDisplayOnLidClose = true
        config.hotspotSSID = ""
        config.tmuxTargets = []
        manager.config = config
        try manager.store.saveConfig(config)
    }

    public func start(seconds: TimeInterval) async -> Bool {
        await prepare()
        await manager.start(duration: seconds)
        publish()
        return manager.isActive && manager.pendingEnd == nil
    }

    public func stop(forQuit: Bool = false) async -> Bool {
        let result = await manager.end(reason: forQuit ? .quit : .user)
        publish()
        return forQuit ? result.letsQuitGo : result == .restored
    }

    public func retryRecovery() async { await manager.reconcile(); publish() }

    public func isAuthorized() async -> Bool {
        for args in [["-a", "disablesleep", "1"], ["-a", "disablesleep", "0"], ["-b", "lowpowermode", "1"], ["-b", "lowpowermode", "0"]] {
            guard let result = try? await CancellableCommand().run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset"] + args, timeout: 5), result.succeeded else { return false }
        }
        return true
    }

    /// macOS displays its own password prompt. The exact four commands are
    /// granted, and the candidate is validated before replacing the rule.
    public func authorize() async -> Bool {
        let user = NSUserName()
        guard !user.isEmpty, user.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".") }) else { return false }
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -b lowpowermode 1, /usr/bin/pmset -b lowpowermode 0\n"
        let shell = "set -eu; candidate=$(/usr/bin/mktemp /etc/sudoers.d/.boring-caffeine.XXXXXX); trap '/bin/rm -f \"$candidate\"' EXIT; /usr/bin/printf '%s' '\(rule)' > \"$candidate\"; /usr/sbin/chown root:wheel \"$candidate\"; /bin/chmod 440 \"$candidate\"; /usr/sbin/visudo -cf \"$candidate\"; /bin/mv -f \"$candidate\" /etc/sudoers.d/boring-caffeine"
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        let script = "do shell script \"\(escaped)\" with administrator privileges with prompt \"Allow Caffeine to keep your Mac working with the lid closed and manage Low Power Mode.\""
        guard let result = try? await CancellableCommand().run("/usr/bin/osascript", ["-e", script], timeout: 300), result.succeeded else { return false }
        return await isAuthorized()
    }

    public static func alwaysKeepsRunning(_ id: String) -> Bool {
        ["com.avast.", "com.malwarebytes.", "com.bitdefender.", "com.sophos.", "com.eset.", "com.crowdstrike.", "com.objective-see.lulu."].contains(where: id.hasPrefix) || id.hasPrefix("com.apple.") || id == Paths.bundleIdentifier || id == FreezePlanner.dockerBundleId || FreezePlanner.meetingApps.contains(id) || FreezePlanner.meetingAppPrefixes.contains(where: id.hasPrefix)
    }
    public static func suggestedToKeep(_ id: String) -> Bool { FreezePlanner.isBuiltInProtected(id) }

    private func observe() {
        withObservationTracking {
            _ = manager.session
            _ = manager.lastError
            _ = manager.state
            _ = manager.services?.status.lidClosed
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.publish()
                self?.observe()
            }
        }
    }

    private func publish() {
        deadline = manager.session?.endsAt
        startedAt = manager.session?.startedAt
        needsRecovery = manager.state.isDirty && !manager.isActive
        pausedAppCount = manager.state.frozenProcesses.count
        lidClosed = manager.services?.status.lidClosed ?? false
        message = manager.lastError == nil ? nil : manager.isActive
            ? "A Caffeine setting couldn’t be applied. Open settings to retry recovery."
            : "Caffeine couldn’t finish restoring your Mac. Keep the app open and try Restore."
        if manager.lastError != nil { Log.error("host status: \(manager.lastError ?? "")") }
    }

    public nonisolated static func runRecoveryCommand() -> Never {
        if let output = ResumeFrozenCommand.run(Array(CommandLine.arguments.dropFirst()), endAfter: ResumeFrozenCommand.endProcess) {
            for line in output.lines { print(line) }
            exit(output.status)
        }
        exit(64)
    }
}
