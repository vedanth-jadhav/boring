import Darwin
import Foundation

/// Everything Caffeine writes under its own two directories is owner-only.
/// boring-caffeine.log and handoffs.log name SSIDs, tmux targets and processes;
/// the journal, session and config files say what the machine is doing.
/// Files are created 0600 and the directories Caffeine owns 0700. A file or
/// directory that already exists with a looser mode (an older build, a
/// copied tree, a wide umask) is tightened when it is next opened.
/// Tightening only clears bits: it never adds one, so a file its owner made
/// unreadable stays that way. A symlink is left alone, together with
/// whatever it points at. So is an access control list: removing entries
/// changes what recovery can read. An allow entry can be what lets the
/// owner read a 0200 journal, and a journal recovery cannot read leaves
/// sleep disabled; a deny entry can be what keeps a session unreadable,
/// which recovery treats as ended. A chmod that fails is reported, not
/// dropped: once per path through `reportOnce` for the journal, config and
/// lock, and as an error thrown after the line is written for the two logs.
/// backstop.sh does the same for what it creates with `umask 077`, and
/// tightens what an older build left loose.
///
/// The two logs are also capped: past `maxLogBytes` the file is renamed to
/// `<name>.1`, replacing the previous `.1`, and the next line starts a new
/// file. The rename runs under flock(2) on the file, with a check that the
/// file held is still the one at the path, so two processes that both find
/// the log oversized cannot rotate it twice and rename the fresh log over
/// the retained copy. A log that is a symlink is never rotated, since the
/// rename would move the link itself; that is reported once, and the cap
/// does not hold for it. The user set up the link, so the file it points to
/// is theirs to trim. The backstop appends with `>>` and never rotates, so
/// it simply creates the fresh file.
enum OwnerOnly {
    static let fileMode: mode_t = 0o600
    static let directoryMode: mode_t = 0o700
    /// 1 MiB. Caffeine writes a few lines a minute at most, so this is weeks
    /// of history, and `.1` doubles it. Not enforced for a symlinked log;
    /// see above.
    static let maxLogBytes: UInt64 = 1 << 20

    /// Creates `dir` and any missing parents, then makes `dir` itself 0700.
    /// Parents are left alone: only Caffeine's own directory is tightened.
    /// Throws when the directory cannot be created; returns the chmod
    /// failure, if any, for the caller to report.
    @discardableResult
    static func createDirectory(_ dir: URL) throws -> OwnerOnlyError? {
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Int(directoryMode)]
        )
        return tighten(path: dir.path, to: directoryMode)
    }

    /// chmod(2) away every permission bit outside `mode`, when there is one.
    /// No bit is added: 0644 becomes 0600 and 0444 becomes 0400. A symlink
    /// is skipped: its target may be shared with other users or
    /// programs and is not Caffeine's to change. Returns the failure, if
    /// any; the read or write that follows goes ahead either way, and the
    /// caller reports the problem.
    static func tighten(path: String, to mode: mode_t = fileMode) -> OwnerOnlyError? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { return nil }
        guard (st.st_mode & 0o777) & ~mode != 0 else { return nil }
        return chmod(path, st.st_mode & 0o777 & mode) == 0 ? nil : .chmod(path: path, errno: errno)
    }

    /// Same, on an open descriptor, so the file checked is the file held.
    /// `path` names it in the error, and a `path` that is a symlink is
    /// skipped as above, since open(2) followed it to the file held.
    static func tighten(fd: Int32, path: String, to mode: mode_t = fileMode) -> OwnerOnlyError? {
        var st = stat()
        guard lstat(path, &st) != 0 || (st.st_mode & S_IFMT) != S_IFLNK else { return nil }
        guard fstat(fd, &st) == 0 else { return nil }
        guard (st.st_mode & 0o777) & ~mode != 0 else { return nil }
        return fchmod(fd, st.st_mode & 0o777 & mode) == 0 ? nil : .chmod(path: path, errno: errno)
    }

    /// Logs a chmod failure once per path per process. Store.read runs on
    /// every transaction and a file this user cannot chmod stays that way,
    /// so one line says it. Not for the logs' own paths: `appendToLog` runs
    /// under the log lock and throws instead.
    static func reportOnce(_ problem: OwnerOnlyError) {
        guard reported.insert(problem.path) else { return }
        Log.error(problem.localizedDescription)
    }

    private static let reported = PathSet()
    private static let symlinkedLogs = PathSet()

    private final class PathSet: @unchecked Sendable {
        private let lock = NSLock()
        private var paths = Set<String>()

        /// True the first time `path` is seen.
        func insert(_ path: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return paths.insert(path).inserted
        }
    }

    /// Appends `text` to the log at `url`: the directory is created 0700,
    /// the file 0600 (an existing file is tightened), and a file already
    /// past `maxBytes` is rotated first so the line lands in a new file.
    /// The line is written even when a chmod or the rotation fails; the
    /// first such failure is then thrown so the caller can report it.
    /// `beforeRotating` runs once the file held is found past the cap and
    /// before its lock is taken; a throw from it ends the append there, with
    /// nothing rotated or written. Tests use it to rotate from outside first.
    static func appendToLog(
        _ text: String,
        at url: URL,
        maxBytes: UInt64 = maxLogBytes,
        beforeRotating: () throws -> Void = {}
    ) throws {
        var problems: [OwnerOnlyError] = []
        if let problem = try createDirectory(url.deletingLastPathComponent()) { problems.append(problem) }
        var fd = try openForAppend(url)
        defer { if fd >= 0 { close(fd) } }
        // Before any rotation, so a legacy 0644 log is 0600 by the time it
        // becomes `.1`.
        if let problem = tighten(fd: fd, path: url.path) { problems.append(problem) }
        if size(of: fd) > maxBytes {
            try beforeRotating()
            switch rotateHeld(fd, at: url, maxBytes: maxBytes) {
            case let .keep(problem):
                // The held file is still the log: keep writing to it.
                if let problem { problems.append(problem) }
            case .reopen:
                // Rotated, by this process or another: the path is a fresh file.
                close(fd)
                fd = -1
                fd = try openForAppend(url)
                if let problem = tighten(fd: fd, path: url.path) { problems.append(problem) }
            }
        }
        try writeAll(Data(text.utf8), to: fd, path: url.path)
        if let first = problems.first { throw first }
    }

    private static func openForAppend(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, fileMode)
        guard fd >= 0 else { throw OwnerOnlyError.open(path: url.path, errno: errno) }
        return fd
    }

    private static func size(of fd: Int32) -> UInt64 {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return 0 }
        return UInt64(max(0, st.st_size))
    }

    /// `<name>.1` next to the log: boring-caffeine.log.1, handoffs.log.1.
    static func rotated(_ url: URL) -> URL { url.appendingPathExtension("1") }

    /// What `rotateHeld` leaves the appender to do.
    private enum Rotation {
        /// The path names a fresh file, whoever rotated: open it.
        case reopen
        /// The held file is still the log: write to it, and report the
        /// problem, if any.
        case keep(OwnerOnlyError?)
    }

    /// rename(2) the held file over the previous `.1`, under flock(2) on it.
    /// Two processes can both find the log oversized; the one that locks
    /// first renames, and the other then sees that the path no longer names
    /// the file it holds and leaves the fresh log alone. The path is read
    /// with lstat(2): a symlinked log is not renamed, because rename moves
    /// the link, not its target, and the next open would start a plain file
    /// in its place. A rename keeps the inode and its mode; the backstop may
    /// still have a line in flight to it, which then lands in `.1`.
    private static func rotateHeld(_ fd: Int32, at url: URL, maxBytes: UInt64) -> Rotation {
        guard flock(fd, LOCK_EX) == 0 else { return .keep(.rotate(path: url.path, errno: errno)) }
        defer { flock(fd, LOCK_UN) }
        var held = stat()
        var named = stat()
        guard fstat(fd, &held) == 0 else { return .keep(.rotate(path: url.path, errno: errno)) }
        if lstat(url.path, &named) != 0 {
            // Gone from the path: another process rotated it and has not
            // written yet. Nothing to rename.
            return errno == ENOENT ? .reopen : .keep(.rotate(path: url.path, errno: errno))
        }
        if (named.st_mode & S_IFMT) == S_IFLNK {
            return .keep(symlinkedLogs.insert(url.path) ? .symlinkNotRotated(path: url.path) : nil)
        }
        guard held.st_ino == named.st_ino, held.st_dev == named.st_dev else { return .reopen }
        guard UInt64(max(0, held.st_size)) > maxBytes else { return .keep(nil) }
        guard rename(url.path, rotated(url).path) == 0 else { return .keep(.rotate(path: url.path, errno: errno)) }
        return .reopen
    }

    /// Creates `url` holding `data`, mode 0600 from the first byte. Fails
    /// when the file exists: callers pass a fresh temp name and rename it.
    static func createFile(at url: URL, contents data: Data) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, fileMode)
        guard fd >= 0 else { throw OwnerOnlyError.open(path: url.path, errno: errno) }
        defer { close(fd) }
        try writeAll(data, to: fd, path: url.path)
    }

    private static func writeAll(_ data: Data, to fd: Int32, path: String) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, base + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw OwnerOnlyError.write(path: path, errno: errno)
                }
                offset += n
            }
        }
    }
}

enum OwnerOnlyError: Error, LocalizedError {
    case open(path: String, errno: Int32)
    case write(path: String, errno: Int32)
    case chmod(path: String, errno: Int32)
    case rotate(path: String, errno: Int32)
    case symlinkNotRotated(path: String)

    var path: String {
        switch self {
        case let .open(path, _), let .write(path, _), let .chmod(path, _), let .rotate(path, _):
            return path
        case let .symlinkNotRotated(path):
            return path
        }
    }

    var errorDescription: String? {
        switch self {
        case let .open(path, errno): return "could not open \(path): \(String(cString: strerror(errno)))"
        case let .write(path, errno): return "could not write \(path): \(String(cString: strerror(errno)))"
        case let .chmod(path, errno): return "could not make \(path) owner-only: \(String(cString: strerror(errno)))"
        case let .rotate(path, errno): return "could not rotate \(path) to \(path).1: \(String(cString: strerror(errno)))"
        case let .symlinkNotRotated(path): return "not rotating \(path): it is a symlink, so its target can grow past the cap"
        }
    }
}
