import Foundation

/// Keeps the launchd agent that runs backstop.sh loaded. The agent is
/// persistent: it runs at load and every minute, and enforces the deadline
/// written in session.json itself, so the app never has to replace the job
/// per extension (which used to leave a window with no agent at all).
///
/// The script it runs is the backstop.sh sealed inside the app bundle
/// (Contents/Resources). The agent's command line verifies the bundle's code
/// signature against the requirement pinned in the plist and only then
/// execs the script, so a backstop.sh edited on disk is never run by
/// launchd. Nothing executable lives in a writable support directory.
///
/// What the app pins is the requirement of the code it is itself running
/// (CodeRequirement.pin), after checking that the bundle on disk still is
/// that code and still passes the agent's check. A bundle edited or
/// re-signed under the running app makes arm() fail, with the reason, rather
/// than report an agent that refuses every run or pin the replacement.
protocol BackstopScheduling: Sendable {
    /// Make sure the polling agent is loaded with the current plist. Cheap
    /// when it already is; throws when it cannot be loaded.
    func arm() async throws
}

struct BackstopError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The bundle whose sealed backstop.sh the agent runs, and the code
/// requirement that bundle must satisfy first.
struct BackstopTarget: Sendable, Equatable {
    let bundle: URL
    /// Designated requirement of the bundle's signature, in requirement
    /// language, as `codesign -d -r-` prints it (see CodeRequirement).
    let requirement: String

    var script: URL { Paths.backstopScript(inBundle: bundle) }
}

struct LaunchdBackstop: BackstopScheduling {
    typealias Runner = @Sendable (_ exe: String, _ args: [String]) async throws -> ShellResult
    /// Returns the requirement to pin for a bundle that satisfies it right
    /// now, or throws with the reason it must not be pinned.
    typealias BundlePinner = @Sendable (_ bundle: URL) throws -> String

    static let launchctl = "/bin/launchctl"
    /// Seconds between backstop.sh runs while loaded. install.sh writes the same value.
    static let pollInterval = 60
    static let commandTimeout: TimeInterval = 15

    /// What launchd runs: `/bin/sh -c <agentProgram> sh <requirement> <bundle>`.
    /// The program verifies the bundle ($2) against the requirement ($1) with
    /// codesign and execs the sealed backstop.sh only when that passes; the
    /// resource seal covers the script, so an edited copy fails here. On
    /// failure it appends one line to ~/Library/Logs/Boring Notch/Caffeine/boring-caffeine.log
    /// (the LaunchAgent only ever exists in the standard layout) and exits 1
    /// without running anything. install.sh embeds this same text (its
    /// AGENT_PROGRAM line); LaunchdBackstopTests checks the two are equal so
    /// the app recognises the plist install.sh wrote. No single quotes, so
    /// the shell can hold it in one.
    static let agentProgram = #"r="$(/usr/bin/codesign --verify --strict "-R=$1" "$2" 2>&1)" && exec /bin/bash "$2/Contents/Resources/backstop.sh"; mkdir -p "$HOME/Library/Logs/Boring Notch/Caffeine"; printf "%s [error] backstop agent: %s does not satisfy the pinned code requirement; backstop.sh not run. Reinstall Caffeine (scripts/install.sh). codesign: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$(printf %s "$r" | tr "\n" " ")" >> "$HOME/Library/Logs/Boring Notch/Caffeine/boring-caffeine.log"; exit 1"#

    let plistURL: URL
    let bundle: URL
    let label: String
    let uid: uid_t
    private let pin: BundlePinner
    private let run: Runner

    /// `bundle` defaults to the bundle this process runs from, and, when it
    /// is not running from one (`swift run`), to the installed bundle at
    /// `paths.appBundle`, so a development build arms the agent against the
    /// installed app's sealed script. `pin` runs at every arm(), so an
    /// upgrade is pinned the first time the upgraded app arms; the default
    /// is CodeRequirement.pin (the running code's own requirement, and the
    /// agent's check on the bundle).
    init(
        paths: Paths,
        bundle: URL? = nil,
        pin: @escaping BundlePinner = { try CodeRequirement.pin(bundle: $0) },
        label: String = Paths.backstopLabel,
        uid: uid_t = getuid(),
        run: @escaping Runner = { try await CancellableCommand().run($0, $1, timeout: LaunchdBackstop.commandTimeout) }
    ) {
        self.plistURL = paths.backstopPlist
        self.bundle = bundle ?? Self.runningOrInstalledBundle(paths: paths)
        self.pin = pin
        self.label = label
        self.uid = uid
        self.run = run
    }

    static func runningOrInstalledBundle(paths: Paths, running: URL = Bundle.main.bundleURL) -> URL {
        running.pathExtension == "app" ? running.standardizedFileURL : paths.appBundle
    }

    var scriptPath: String { Paths.backstopScript(inBundle: bundle).path }

    func arm() async throws {
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw BackstopError(message: "backstop.sh is not sealed in the app bundle at \(scriptPath); run scripts/install.sh")
        }
        // Before trusting a loaded agent: the bundle it would verify must
        // pass that verification now. A sealed script edited after signing
        // leaves the plist current and the job loaded, but the agent refuses
        // every run; that is not armed.
        let requirement: String
        do {
            requirement = try pin(bundle)
        } catch {
            throw BackstopError(message: "the recovery agent cannot pin \(bundle.path): \(error.localizedDescription). Reinstall with scripts/install.sh")
        }
        let desired = Self.plistDictionary(label: label, target: BackstopTarget(bundle: bundle, requirement: requirement))
        // Armed when the plist the next login loads is this build's and the
        // loaded job is the one it describes: the same command line, started
        // every `pollInterval` seconds. A loaded label alone may be another
        // build's job, pinning a bundle or requirement this one does not
        // satisfy (install.sh can leave one loaded when it stops between its
        // bootstrap and publishing the plist), or a job loaded from a plist
        // without the interval, which never runs again to end a session.
        if plistOnDiskMatches(desired), try await loadedJob() == LoadedJob(plist: desired) {
            return
        }
        // The plist at `plistURL` is what the next arm() trusts when the
        // loaded job is the one it describes, so it may only ever hold a
        // plist launchd actually loaded. Load through a private
        // candidate and publish it with one rename after bootstrap succeeded.
        // A failed replacement (bootout left the old job loaded, bootstrap
        // refused, volume stopped taking writes) then leaves the trusted path
        // exactly as it was, whether or not any cleanup below works.
        let candidate = try writeCandidate(desired)
        defer { discard(candidate) }
        try await reload(from: candidate)
        try publish(candidate)
    }

    // MARK: Plist

    /// Pure builder, testable without launchd. Must produce exactly what
    /// install.sh writes, or every arm() reloads the agent.
    static func plistDictionary(label: String, target: BackstopTarget) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": ["/bin/sh", "-c", agentProgram, "sh", target.requirement, target.bundle.path],
            "RunAtLoad": true,
            "StartInterval": pollInterval,
        ]
    }

    func plistOnDiskMatches(_ desired: [String: Any]) -> Bool {
        guard let data = try? Data(contentsOf: plistURL),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return NSDictionary(dictionary: obj).isEqual(to: desired)
    }

    /// Candidates are `*.plist` files in a private subdirectory of the
    /// LaunchAgents directory. launchctl refuses to bootstrap (or boot out)
    /// any path without a `.plist` suffix with EIO, so the name must end in
    /// `.plist`; launchd's login-time load of the LaunchAgents directory does
    /// not descend into subdirectories, so a candidate left behind by a
    /// crash or an unwritable volume can never be picked up as a second copy
    /// of the label; and one level below the trusted plist is still the same
    /// filesystem, so publishing stays a single rename.
    private var stagingDirectory: URL {
        plistURL.deletingLastPathComponent().appendingPathComponent(".\(label).staging", isDirectory: true)
    }
    private var candidatePrefix: String { "\(label).candidate-" }

    private func writeCandidate(_ desired: [String: Any]) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: desired, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        sweepCandidates()
        let url = stagingDirectory.appendingPathComponent(candidatePrefix + UUID().uuidString + ".plist")
        try data.write(to: url)
        return url
    }

    /// Atomically replaces the trusted plist with the candidate launchd just
    /// loaded. Throws when that fails: the agent is running for this login
    /// session, but the plist launchd reads at the next login is still the
    /// old one, so the caller must not treat the backstop as configured.
    private func publish(_ candidate: URL) throws {
        guard rename(candidate.path, plistURL.path) == 0 else {
            let reason = String(cString: strerror(errno))
            throw BackstopError(message: "backstop agent loaded but its plist could not be published to \(plistURL.path): \(reason)")
        }
    }

    /// Best effort; after a successful publish the candidate is already gone
    /// and only the (then empty) staging directory is left to remove.
    private func discard(_ candidate: URL) {
        if FileManager.default.fileExists(atPath: candidate.path) {
            do {
                try FileManager.default.removeItem(at: candidate)
            } catch {
                // Harmless to launchd (see stagingDirectory); swept by the next arm().
                Log.error("could not remove backstop candidate plist \(candidate.lastPathComponent): \(error.localizedDescription)")
            }
        }
        // Fails while a candidate is still inside; that is fine.
        _ = rmdir(stagingDirectory.path)
    }

    private func sweepCandidates() {
        let fm = FileManager.default
        // The LaunchAgents directory itself too: an older build staged its
        // candidates there, and a leftover makes launchd's directory load
        // report an error at every login.
        for dir in [stagingDirectory, plistURL.deletingLastPathComponent()] {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(candidatePrefix) {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    // MARK: launchctl

    /// What `launchctl print` shows of a loaded job that makes it this
    /// build's polling agent: the command it runs and how often launchd
    /// starts it.
    struct LoadedJob: Equatable, Sendable {
        var arguments: [String]
        /// StartInterval in seconds; nil when the job has none, so launchd
        /// never starts it again by itself.
        var runInterval: Int?

        init(arguments: [String], runInterval: Int?) {
            self.arguments = arguments
            self.runInterval = runInterval
        }

        /// The job a plist from `plistDictionary` loads as.
        init(plist: [String: Any]) {
            self.init(arguments: plist["ProgramArguments"] as? [String] ?? [], runInterval: plist["StartInterval"] as? Int)
        }
    }

    /// The loaded job, from `launchctl print`: nil when no job with the
    /// label is loaded or the output cannot be read.
    func loadedJob() async throws -> LoadedJob? {
        let r = try await run(Self.launchctl, ["print", "gui/\(uid)/\(label)"])
        return r.succeeded ? Self.loadedJob(fromPrint: r.stdout) : nil
    }

    /// Reads `launchctl print <service>` output, whose top-level keys are
    /// indented by one tab. `arguments = {` opens a block of one argument per
    /// line, indented by two tabs, closed by `\t}`; `run interval = <n>
    /// seconds` is there only for a job with a StartInterval. nil when the
    /// arguments block is missing, repeated, unclosed or holds a line this
    /// does not know; a run interval in another form reads as none. Either
    /// way the job does not match a plist, and arm() reloads it.
    static func loadedJob(fromPrint output: String) -> LoadedJob? {
        let intervalPrefix = "\trun interval = ", intervalSuffix = " seconds"
        var arguments: [String]?
        var inArguments = false
        var runInterval: Int?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if inArguments {
                if line == "\t}" {
                    inArguments = false
                } else if line.hasPrefix("\t\t") {
                    arguments?.append(String(line.dropFirst(2)))
                } else {
                    return nil
                }
            } else if line == "\targuments = {" {
                guard arguments == nil else { return nil }
                arguments = []
                inArguments = true
            } else if line.hasPrefix(intervalPrefix), line.hasSuffix(intervalSuffix) {
                runInterval = Int(line.dropFirst(intervalPrefix.count).dropLast(intervalSuffix.count))
            }
        }
        guard let arguments, !inArguments else { return nil }
        return LoadedJob(arguments: arguments, runInterval: runInterval)
    }

    /// bootout by service target (ignored if not loaded: the trusted path may
    /// not exist yet, and a path launchctl cannot read fails with EIO rather
    /// than unloading anything), then bootstrap from the candidate. RunAtLoad
    /// means the script runs immediately; it is a no-op while the session on
    /// disk is valid and the journal is clean.
    ///
    /// Throws when the agent cannot be loaded: a session must never hold
    /// sleep without an agent that will release it.
    private func reload(from candidate: URL) async throws {
        let domain = "gui/\(uid)"
        _ = try await run(Self.launchctl, ["bootout", "\(domain)/\(label)"])
        let r = try await run(Self.launchctl, ["bootstrap", domain, candidate.path])
        if !r.succeeded {
            throw BackstopError(message: "launchctl bootstrap failed (\(r.status)): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
