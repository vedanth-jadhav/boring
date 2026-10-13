import Foundation

/// A `sudo pmset` that did not stop on SIGTERM and still holds the recovery
/// lock (`Paths.unfinishedCommandFile`). Only read to name the command when
/// the lock is busy: after a crash or force quit, the relaunched app cannot
/// take the lock until the command exits, and says which one to stop.
struct UnfinishedCommandRecord: Codable, Equatable, Sendable {
    var pid: Int32
    var command: String
    var since: Date
    /// The command's start time and boot session (`UnfinishedCommand`).
    /// The pid is named as the command only while the live process still
    /// has them: once the command exits, the pid can go to an unrelated
    /// process. nil when they could not be read, or in a record written
    /// before they were kept; the pid is then never named.
    var identity: ProcessIdentity?
}
