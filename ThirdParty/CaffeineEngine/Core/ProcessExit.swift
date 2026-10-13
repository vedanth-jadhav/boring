import Foundation

/// Waits for a child `Process` to exit. Use it instead of
/// `Process.waitUntilExit()`, which can wait forever for a child that has
/// already exited and been reaped.
///
/// On macOS 26, `waitUntilExit()` polls the calling thread's run loop every
/// 62.5 ms. If the task has no `terminationHandler` and the calling thread
/// looks like the one that launched it, the poll also waits for the
/// termination notification, which Foundation queues on the launching
/// thread's run loop. Foundation decides "launched here" by looking for the
/// task's address in a per-thread list that every launch appends to and
/// nothing prunes. A new `Process` at the address of one this thread launched
/// earlier, launched by another thread, matches. If the launching thread
/// never runs its run loop (a GCD or Swift concurrency worker), the
/// notification never goes out and the wait never returns.
///
/// This waits for `terminationHandler`, which Foundation calls on a dispatch
/// queue after it has reaped the child, whichever thread launched it. Create
/// it before `run()`: it replaces the process's `terminationHandler`. Wait
/// only after `run()` succeeded; a child that never started never exits.
final class ProcessExit: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var suspended: [CheckedContinuation<Void, Never>] = []
    /// Signalled once on exit. Each blocking waiter takes the signal and puts
    /// it back, so any number of waiters return.
    private let exitSignal = DispatchSemaphore(value: 0)

    init(_ process: Process) {
        process.terminationHandler = { [self] _ in finish() }
    }

    private func finish() {
        let resume = lock.withLock {
            done = true
            defer { suspended = [] }
            return suspended
        }
        exitSignal.signal()
        for continuation in resume { continuation.resume() }
    }

    /// Blocks the calling thread until the child has exited and been reaped,
    /// so `terminationStatus` and `terminationReason` are final. For threads
    /// that may block; async code awaits `exited()` instead.
    func wait() {
        exitSignal.wait()
        exitSignal.signal()
    }

    /// Suspends until the child has exited and been reaped, without holding
    /// a thread.
    func exited() async {
        await withCheckedContinuation { continuation in
            let already = lock.withLock {
                if !done { suspended.append(continuation) }
                return done
            }
            if already { continuation.resume() }
        }
    }

    /// How many `exited()` callers are suspended right now. Tests read it to
    /// let the child exit only after a caller has suspended.
    var suspendedCount: Int { lock.withLock { suspended.count } }
}
