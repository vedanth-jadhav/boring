import Foundation
import os

/// Unified logging plus a plain-text line appended to boring-caffeine.log, which is
/// shared with backstop.sh so one file tells the whole story.
///
/// The unified log is readable by every program running as the user (and
/// by anyone with a sysdiagnose), so message bodies go there as private
/// data: `log show` prints `<private>` in their place. The bodies name
/// SSIDs, tmux targets, process names and bundle ids. boring-caffeine.log keeps
/// the full text for the user; its permissions are its own protection.
enum Log {
    static let logger = Logger(subsystem: Paths.bundleIdentifier, category: "core")
    private static let lock = NSLock()

    static func info(_ message: String) {
        logger.info("\(message, privacy: .private)")
        append(level: "info", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .private)")
        append(level: "error", message)
    }

    static func append(level: String, _ message: String, paths: Paths = .fromEnvironment()) {
        let now = Date().formatted(.iso8601.year().month().day().dateTimeSeparator(.standard).time(includingFractionalSeconds: false).timeZone(separator: .omitted))
        let line = "\(now) [\(level)] boring-caffeine: \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        do {
            // Owner-only, and rotated to boring-caffeine.log.1 past OwnerOnly.maxLogBytes.
            // A chmod or rotation that fails is thrown after the line is
            // written, so it reaches the unified log below.
            try OwnerOnly.appendToLog(line, at: paths.logFile)
        } catch {
            // The description carries a path under the home directory.
            logger.error("boring-caffeine.log: \(error.localizedDescription, privacy: .private)")
        }
    }
}
