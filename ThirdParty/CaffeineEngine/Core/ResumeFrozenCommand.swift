import Darwin
import Foundation

/// `Caffeine --resume-frozen <seconds>`, journal entries on standard input
///
/// One-shot mode for backstop.sh. The shell can read a process's start time
/// only to the second (`ps -o lstart`), so for the journal entries that
/// record microseconds it asks this binary to do what the app does on lid
/// open, through the same `SignalProcessControl.resume`: for each entry in
/// turn, one kernel lookup (start time to the microsecond, boot session,
/// stopped state) immediately followed by that entry's SIGCONT, before the
/// next entry is looked up. One launch covers every entry. Nothing else
/// runs: no AppKit, no journal, no lock of its own (the caller holds the
/// recovery lock and rewrites the journal from the answer).
///
/// `<seconds>` is how long this process may live, a whole number from 1 to
/// 300. Before it reads anything it arranges to end itself with SIGALRM
/// that many seconds later, whatever SIGALRM disposition and mask it
/// inherited. backstop.sh passes its own time limit and runs this mode with
/// the recovery lock open on fd 9, so the lock stays held for as long as
/// this process can send a signal, even when the shell that started it dies
/// first; the time limit then frees the lock without anyone waiting for it.
///
/// Standard input holds one entry per line, `<pid> <startedAt>
/// <startedAtMicros> <bootSession>`: four fields, one space between them,
/// every line ending in a newline. Standard input has no size limit, unlike
/// the argument list (ARG_MAX), so a journal of any length fits in one
/// call. Prints one line per entry, in input order, `<pid> <word>`:
///
///     resumed       identity matched, the process was stopped, SIGCONT delivered
///     gone          no such pid, running, or a different process: nothing to do
///     failed        identity matched, SIGCONT failed; try again later
///     unobserved    the kernel would not say what the pid is; try again later
///     unverifiable  the fallthrough for an answer with no boot session to compare; never signaled
///
/// Exits 0 when every entry is `resumed` or `gone`, 1 when any is not. A
/// missing or malformed `<seconds>`, any further argument, empty input, or
/// a malformed line prints the single line `usage` (details on stderr),
/// checks nothing, and exits 64. The shell clears an entry on `resumed` and
/// `gone` and keeps it otherwise, and keeps every entry when the answer is
/// not exactly this shape.
///
/// The app bundle declares this interface as `CaffeineResumeFrozenVersion`
/// (`version`) in its Info.plist. backstop.sh runs the binary only when the
/// installed bundle declares the version the script speaks, so it never
/// starts an older build, which would open the menu bar app instead.
enum ResumeFrozenCommand {
    static let flag = "--resume-frozen"
    /// `CaffeineResumeFrozenVersion` in Resources/Info.plist, and
    /// RESUME_FROZEN_VERSION in backstop.sh and uninstall.sh.
    static let version = 1
    /// EX_USAGE from sysexits(3).
    static let usageStatus: Int32 = 64
    /// The longest lifetime the caller may ask for.
    static let maxLifetimeSeconds: UInt32 = 300

    enum Answer: String, Sendable {
        case resumed, gone, failed, unobserved, unverifiable

        /// Nothing left to do for the entry: the shell may clear it.
        var settled: Bool { self == .resumed || self == .gone }
    }

    struct Output: Equatable, Sendable {
        let lines: [String]
        let status: Int32
    }

    /// nil when `arguments` (the command line without the executable) do
    /// not ask for this mode. `endAfter` gets the lifetime once the
    /// arguments are valid, before `input` is read (`endProcess` in the
    /// binary).
    static func run(
        _ arguments: [String],
        input: () -> Data = { FileHandle.standardInput.readDataToEndOfFile() },
        control: any ProcessSignaling = SignalProcessControl(),
        endAfter: (UInt32) -> Void
    ) -> Output? {
        guard arguments.first == flag else { return nil }
        guard arguments.count == 2, let seconds = lifetime(arguments[1]) else { return usage() }
        endAfter(seconds)
        guard let text = String(data: input(), encoding: .utf8),
              let entries = parse(text)
        else { return usage() }
        var lines: [String] = []
        var settled = true
        for entry in entries {
            // One entry per call: its lookup and its signal, then the next.
            let answer = answer(of: control.resume([entry]), pid: entry.pid)
            lines.append("\(entry.pid) \(answer.rawValue)")
            if !answer.settled { settled = false }
        }
        return Output(lines: lines, status: settled ? 0 : 1)
    }

    private static func usage() -> Output {
        FileHandle.standardError.write(Data("usage: Caffeine \(flag) <seconds 1-\(maxLifetimeSeconds)> < entries, one line each: <pid> <startedAt> <startedAtMicros> <bootSession>\n".utf8))
        return Output(lines: ["usage"], status: usageStatus)
    }

    /// The lifetime argument: one to three ASCII digits, 1 to
    /// `maxLifetimeSeconds`; nil otherwise.
    static func lifetime(_ text: String) -> UInt32? {
        guard (1...3).contains(text.utf8.count),
              text.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              let seconds = UInt32(text),
              (1...maxLifetimeSeconds).contains(seconds)
        else { return nil }
        return seconds
    }

    /// Ends this process with SIGALRM `seconds` from now. A disposition of
    /// SIG_IGN and a blocked mask both survive exec, so a parent that
    /// ignored or blocked SIGALRM must not make the limit void: the default
    /// action and an unblocked mask are restored first.
    static func endProcess(after seconds: UInt32) {
        signal(SIGALRM, SIG_DFL)
        var alarmOnly = sigset_t()
        sigemptyset(&alarmOnly)
        sigaddset(&alarmOnly, SIGALRM)
        pthread_sigmask(SIG_UNBLOCK, &alarmOnly, nil)
        alarm(seconds)
    }

    /// The journal entries the input describes, in order; nil unless it has
    /// at least one line, every line ends in a newline, and every line is
    /// four well-formed fields with one space between them.
    static func parse(_ text: String) -> [FrozenProcess]? {
        let scalars = text.unicodeScalars
        guard scalars.last == "\n" else { return nil }
        var entries: [FrozenProcess] = []
        for line in scalars.dropLast().split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false).map { String($0) }
            guard let entry = entry(fields) else { return nil }
            entries.append(entry)
        }
        return entries
    }

    /// One entry from its four fields; nil unless the pid is positive, the
    /// start second non-negative, the microseconds below one million and
    /// the boot session non-empty without white space.
    static func entry(_ fields: [String]) -> FrozenProcess? {
        guard fields.count == 4,
              let pid = Int32(fields[0]), pid > 0,
              let startedAt = Int64(fields[1]), startedAt >= 0,
              let micros = Int32(fields[2]), (0..<1_000_000).contains(micros),
              !fields[3].isEmpty,
              !fields[3].unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
        else { return nil }
        return FrozenProcess(pid: pid, identity: ProcessIdentity(startedAt: startedAt, startedAtMicros: micros, bootSession: fields[3]))
    }

    static func answer(of report: ResumeReport, pid: Int32) -> Answer {
        if report.resumed.contains(pid) { return .resumed }
        if report.gone.contains(pid) { return .gone }
        if report.failed.contains(pid) { return .failed }
        if report.unobserved.contains(pid) { return .unobserved }
        return .unverifiable
    }
}
