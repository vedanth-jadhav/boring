import Foundation

/// Spec section 7: after a long outage, type `continue` into every listed
/// tmux pane that the user has marked for nudges, and press Enter only when
/// `Config.tmuxNudgePressesEnter` is on. Failures are logged, never thrown.
///
/// A pane is marked with a pane-scoped tmux user option:
///
///     tmux set-option -p -t <target> @boring-caffeine-nudge on
///
/// The mark is read fresh before every send with `show-options -p` on the
/// concrete pane and without `-A`, so an option set on the session or the
/// window never counts: only a pane the user marked on purpose is touched.
/// An unmarked pane is skipped and logged.
///
/// Automation boundary: a keystroke that has reached tmux cannot be taken
/// back. So the loop re-checks, before *every* target, that its task is not
/// cancelled and that the session which asked for the nudge still exists,
/// and the live runner checks cancellation again before each command. The
/// live runner also refuses a pane whose state it cannot verify or where
/// keys would not reach the program (dead, in copy/choose mode, input off).
/// Residual risk, not closable from outside tmux: the flags above cannot
/// show text the pane's program has buffered but not yet submitted. If a
/// half-typed line is pending, `continue` is appended to it, and with Enter
/// enabled the whole line is submitted. That is why Enter is off by default
/// and why the mark should go on a dedicated pane.
struct TmuxNudge: Sendable {
    static let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]

    /// `display-message -p -F` format the live runner reads before sending.
    static let paneStateFormat = "#{pane_id} #{pane_dead} #{pane_in_mode} #{pane_input_off}"
    /// Pane-scoped user option that marks a pane as nudgeable.
    static let markOption = "@boring-caffeine-nudge"
    /// The command the user runs to mark a pane; shown in Settings.
    static func markCommand(target: String = "<target>") -> String {
        "tmux set-option -p -t \(target) \(markOption) on"
    }

    /// `pressEnter` says whether Enter follows `continue`. Returns false
    /// after logging why nothing was sent; the caller only counts.
    typealias Runner = @Sendable (_ target: String, _ pressEnter: Bool) async throws -> Bool
    /// Asked before each target; `false` ends the nudge because the session
    /// that requested it is gone.
    typealias Permission = @MainActor @Sendable () -> Bool

    enum PaneCheck: Equatable, Sendable {
        /// `paneId` is the concrete `%N` pane the flags were read from.
        case ready(paneId: String)
        case skip(reason: String)
    }

    let run: Runner

    init(run: Runner? = nil) {
        self.run = run ?? TmuxNudge.liveRunner
    }

    /// Returns the number of targets that accepted the keystroke.
    @discardableResult
    func nudge(targets: [String], pressEnter: Bool = false, permitted: @escaping Permission = { true }) async -> Int {
        var count = 0
        for target in targets where !target.isEmpty {
            if Task.isCancelled {
                Log.info("tmux nudge to \(target) skipped: cancelled")
                break
            }
            guard await permitted() else {
                Log.info("tmux nudge to \(target) skipped: session stopped")
                break
            }
            do {
                if try await run(target, pressEnter) {
                    count += 1
                    Log.info("tmux nudge sent to \(target): continue\(pressEnter ? " + Enter" : "")")
                }
            } catch {
                Log.error("tmux nudge to \(target) failed: \(error.localizedDescription)")
            }
        }
        return count
    }

    /// Decides from `display-message -p -F paneStateFormat` output whether
    /// `send-keys` may run, and to which concrete pane. Anything but a `%N`
    /// pane id followed by three clean 0/1 flags is unverifiable and
    /// skipped: tmux prints blank fields, with exit 0, for a target it
    /// cannot resolve.
    static func check(paneState output: String) -> PaneCheck {
        let fields = output.split(whereSeparator: { $0 == " " || $0.isNewline }).map(String.init)
        let shown = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fields.count == 4, fields[1...].allSatisfy({ $0 == "0" || $0 == "1" }) else {
            return .skip(reason: "pane state unverifiable (\(shown.isEmpty ? "no such pane" : shown))")
        }
        let id = fields[0]
        guard id.hasPrefix("%"), id.count > 1, id.dropFirst().allSatisfy(\.isNumber) else {
            return .skip(reason: "pane id unverifiable (\(shown))")
        }
        if fields[1] == "1" { return .skip(reason: "pane \(id) is dead") }
        if fields[2] == "1" { return .skip(reason: "pane \(id) is in copy/choose mode; keys would not reach the program") }
        if fields[3] == "1" { return .skip(reason: "pane \(id) input is disabled") }
        return .ready(paneId: id)
    }

    /// Whether `show-options -qpv -t <pane> @boring-caffeine-nudge` output marks
    /// the pane. Exactly `on`, which tmux prints followed by one newline; an
    /// unset option prints nothing. Nothing is trimmed: tmux prints the value
    /// as set, and ` on ` is not the value `markCommand` tells the user to set.
    static func isMarked(showOptionsOutput output: String) -> Bool {
        output == "on\n" || output == "on"
    }

    static let liveRunner: Runner = makeLiveRunner()

    /// `socketName` selects a private tmux server (`tmux -L`); nil is the
    /// user's default server. `command` runs each tmux invocation.
    static func makeLiveRunner(socketName: String? = nil, command: CancellableCommand = CancellableCommand()) -> Runner {
        { target, pressEnter in
            guard let tmux = Shell.locate(candidates) else {
                throw ShellError.launchFailed(exe: "tmux", underlying: "not found in \(candidates.joined(separator: ", "))")
            }
            let server = socketName.map { ["-L", $0] } ?? []
            try Task.checkCancellation()
            let state = try await command.run(tmux, server + ["display-message", "-p", "-t", target, "-F", paneStateFormat], timeout: 5)
            guard state.succeeded else {
                Log.error("tmux display-message -t \(target): \(state.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
                return false
            }
            let paneId: String
            switch check(paneState: state.stdout) {
            case let .skip(reason):
                Log.error("tmux nudge to \(target) skipped: \(reason)")
                return false
            case let .ready(id):
                paneId = id
            }
            // The mark, read on the concrete pane and without -A: a value
            // inherited from the window or session must not count. -q makes
            // an unset option print nothing with exit 0.
            try Task.checkCancellation()
            let mark = try await command.run(tmux, server + ["show-options", "-qpv", "-t", paneId, markOption], timeout: 5)
            // A failed lookup (the server went away after the state read)
            // says nothing about the mark, so it is tmux's error, not a
            // skip. A pane that closed in that window is not a failure here:
            // with -q, tmux 3.6 prints nothing and exits 0 for it.
            guard mark.succeeded else {
                Log.error("tmux show-options -t \(paneId) (\(target)): \(mark.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
                return false
            }
            // An unmarked pane is the expected state of a target listed
            // before marks existed, so this is a skip, not an error.
            guard isMarked(showOptionsOutput: mark.stdout) else {
                Log.info("tmux nudge to \(target) skipped: pane \(paneId) is not marked for nudges; mark it with: \(markCommand(target: paneId))")
                return false
            }
            // Send to the concrete pane whose state was just read, never back
            // through the alias: a session or window target re-resolves to
            // whichever pane is active at send time. The pane's own state
            // can still change in this window.
            try Task.checkCancellation()
            let keys = pressEnter ? ["continue", "Enter"] : ["continue"]
            let r = try await command.run(tmux, server + ["send-keys", "-t", paneId] + keys, timeout: 5)
            if !r.succeeded {
                Log.error("tmux send-keys -t \(paneId) (\(target)): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return r.succeeded
        }
    }
}
