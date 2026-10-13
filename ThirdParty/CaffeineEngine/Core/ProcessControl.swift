import Darwin
import Foundation

/// Sending signals to processes Caffeine froze. Tree discovery and the
/// denylist live in `Freezer`; this is only the signal layer.
///
/// Ownership rule: Caffeine only ever resumes a process it stopped itself.
/// A process that was already stopped is never stopped "again" and so is
/// never resumed; a pid whose identity no longer matches the journal is a
/// different process and is left alone.
///
/// Residual limitation: POSIX offers no atomic "check identity and signal"
/// for a pid. Each signal is sent immediately after its own lookup, which
/// keeps the window to one process's worth of time rather than a whole
/// batch, but a pid reused inside that window cannot be ruled out.
protocol ProcessSignaling: Sendable {
    /// SIGSTOP each process whose parent and identity still match and which
    /// is not already stopped. Everything else is reported as skipped so the
    /// caller can drop it from the journal.
    func suspend(_ processes: [FrozenProcess], expectedParents: [Int32: Int32]) -> SuspendReport
    /// SIGCONT each journaled process that is still stopped and still the
    /// same process. The report says what needs to stay journaled.
    func resume(_ processes: [FrozenProcess]) -> ResumeReport
    /// Undo SIGSTOPs this run sent moments ago: SIGCONT each process that is
    /// still the same process (identity to the microsecond, boot session),
    /// whether or not it shows as stopped yet. A stop signal can still be
    /// pending when the target is looked up, so it may look running; POSIX
    /// discards a pending stop when SIGCONT is generated, so the SIGCONT
    /// cancels it either way. Never signals an entry without identity, a
    /// different process, or a pid that is gone. Only for stops this
    /// process just sent; a journaled entry from an earlier run goes
    /// through `resume`, which signals only a stopped process.
    func cancelStops(_ processes: [FrozenProcess]) -> ResumeReport
}

struct SuspendReport: Sendable, Equatable {
    /// SIGSTOP sent; these are ours to resume. The stop may still be
    /// pending when this returns, so the target can still look running.
    var suspended: [Int32] = []
    /// Already stopped, exited, reparented, reused, or the signal failed:
    /// not ours, must not stay journaled.
    var skipped: [Int32] = []
}

struct ResumeReport: Sendable, Equatable {
    var resumed: [Int32] = []
    /// Verified as ours and still stopped, but SIGCONT failed. Stays journaled.
    var failed: [Int32] = []
    /// Still stopped, but journaled without identity, so ownership cannot
    /// be proven. Stays journaled and is reported to the user.
    var unverifiable: [Int32] = []
    /// The kernel would not say what the pid is doing (permission denied,
    /// transient error). Unknown is not gone: stays journaled and is retried.
    var unobserved: [Int32] = []
    /// Exited, already running, or a different process now: nothing to do.
    var gone: [Int32] = []
}

struct ProcessSignalState: Sendable, Equatable {
    let ppid: Int32
    let stopped: Bool
    let identity: ProcessIdentity

    init(ppid: Int32, stopped: Bool, identity: ProcessIdentity) {
        self.ppid = ppid
        self.stopped = stopped
        self.identity = identity
    }
}

/// What one lookup of a pid found. Absence is only claimed when the kernel
/// confirmed it; a failed read is reported as such, never as "gone".
enum ProcessLookup: Sendable, Equatable {
    case present(ProcessSignalState)
    /// ESRCH: no such process.
    case absent
    /// proc_pidinfo failed for another reason (errno); state unknown.
    case unreadable(Int32)
}

struct SignalProcessControl: ProcessSignaling {
    typealias StateLookup = @Sendable (Int32) -> ProcessLookup
    /// kill(2) as a function returning 0 or errno, so tests never signal a
    /// real pid.
    typealias Sender = @Sendable (Int32, Int32) -> Int32

    private let stateLookup: StateLookup
    private let send: Sender

    init(
        stateLookup: @escaping StateLookup = SignalProcessControl.kernelState,
        send: @escaping Sender = SignalProcessControl.kernelSend
    ) {
        self.stateLookup = stateLookup
        self.send = send
    }

    func suspend(_ processes: [FrozenProcess], expectedParents: [Int32: Int32]) -> SuspendReport {
        var report = SuspendReport()
        for p in processes {
            // Lookup and signal back to back, per process.
            guard Self.isSuspendable(p, expectedParents: expectedParents, stateLookup: stateLookup) else {
                Log.info("SIGSTOP \(p.pid) skipped: already stopped, exited, unreadable, or not the same process")
                report.skipped.append(p.pid)
                continue
            }
            let err = send(p.pid, SIGSTOP)
            if err == 0 {
                report.suspended.append(p.pid)
            } else {
                if err != ESRCH { Log.error("SIGSTOP \(p.pid) failed: \(String(cString: strerror(err)))") }
                report.skipped.append(p.pid)
            }
        }
        return report
    }

    func resume(_ processes: [FrozenProcess]) -> ResumeReport {
        continueEach(processes) { Self.resumeDecision($0, stateLookup: stateLookup) }
    }

    func cancelStops(_ processes: [FrozenProcess]) -> ResumeReport {
        continueEach(processes) { Self.cancelDecision($0, stateLookup: stateLookup) }
    }

    /// SIGCONT per process as `decide` says, each signal right after that
    /// process's own lookup.
    private func continueEach(_ processes: [FrozenProcess], decide: (FrozenProcess) -> ResumeDecision) -> ResumeReport {
        var report = ResumeReport()
        for p in processes {
            // Lookup and signal back to back, per process.
            switch decide(p) {
            case .gone:
                report.gone.append(p.pid)
            case .unverifiable:
                report.unverifiable.append(p.pid)
            case .unobserved:
                report.unobserved.append(p.pid)
            case .signal:
                let err = send(p.pid, SIGCONT)
                if err == 0 {
                    report.resumed.append(p.pid)
                } else if err == ESRCH {
                    report.gone.append(p.pid)
                } else {
                    Log.error("SIGCONT \(p.pid) failed: \(String(cString: strerror(err)))")
                    report.failed.append(p.pid)
                }
            }
        }
        return report
    }

    /// Whether `p` is the process we planned to stop (same parent, same
    /// identity, a real boot session on both sides) and is running right
    /// now. An already-stopped process was stopped by someone else and is
    /// not ours to own; an unreadable one is not owned either.
    static func isSuspendable(
        _ p: FrozenProcess,
        expectedParents: [Int32: Int32],
        stateLookup: StateLookup
    ) -> Bool {
        guard p.pid > 0, let identity = p.identity, let expected = expectedParents[p.pid] else { return false }
        guard !identity.bootSession.isEmpty else {
            Log.error("SIGSTOP \(p.pid) skipped: no boot session in its identity, so it could never be proven ours again")
            return false
        }
        guard case let .present(state) = stateLookup(p.pid) else { return false }
        guard !state.identity.bootSession.isEmpty else { return false }
        return state.ppid == expected && state.identity == identity && !state.stopped
    }

    /// Batch form of `isSuspendable`, for planning and tests.
    static func suspendable(
        _ processes: [FrozenProcess],
        expectedParents: [Int32: Int32],
        stateLookup: StateLookup
    ) -> [Int32] {
        processes.filter { isSuspendable($0, expectedParents: expectedParents, stateLookup: stateLookup) }.map(\.pid)
    }

    enum ResumeDecision: Equatable {
        case signal, unverifiable, unobserved, gone
    }

    /// One journaled entry: send SIGCONT, keep as unverifiable, keep as
    /// unobserved, or clear as gone. Pure, so the ownership rule is testable
    /// without a kernel.
    static func resumeDecision(_ p: FrozenProcess, stateLookup: StateLookup) -> ResumeDecision {
        guard p.pid > 0 else { return .gone }
        let state: ProcessSignalState
        switch stateLookup(p.pid) {
        case .absent: return .gone
        case .unreadable: return .unobserved
        case let .present(s): state = s
        }
        // Already running: nothing left to resume.
        guard state.stopped else { return .gone }
        // Stopped, but the journal cannot prove Caffeine stopped it.
        guard let identity = p.identity, !identity.bootSession.isEmpty else { return .unverifiable }
        // The kernel side has no boot session right now (sysctl failed):
        // the comparison cannot be made, so try again later.
        guard !state.identity.bootSession.isEmpty else { return .unobserved }
        return state.identity == identity ? .signal : .gone // reused pid
    }

    /// `resumeDecision` for a stop this process just sent (`cancelStops`):
    /// the same identity check, but a matching process that does not show
    /// as stopped is signaled too, because its SIGSTOP may still be pending.
    /// An entry without identity is never signaled.
    static func cancelDecision(_ p: FrozenProcess, stateLookup: StateLookup) -> ResumeDecision {
        guard p.pid > 0 else { return .gone }
        guard let identity = p.identity, !identity.bootSession.isEmpty else { return .unverifiable }
        let state: ProcessSignalState
        switch stateLookup(p.pid) {
        case .absent: return .gone
        case .unreadable: return .unobserved
        case let .present(s): state = s
        }
        guard !state.identity.bootSession.isEmpty else { return .unobserved }
        return state.identity == identity ? .signal : .gone // exited and reused
    }

    /// Batch form of `resumeDecision`, for tests.
    static func resumePlan(
        _ processes: [FrozenProcess],
        stateLookup: StateLookup
    ) -> (signal: [Int32], unverifiable: [Int32], unobserved: [Int32], gone: [Int32]) {
        var signal: [Int32] = []
        var unverifiable: [Int32] = []
        var unobserved: [Int32] = []
        var gone: [Int32] = []
        for p in processes {
            switch resumeDecision(p, stateLookup: stateLookup) {
            case .signal: signal.append(p.pid)
            case .unverifiable: unverifiable.append(p.pid)
            case .unobserved: unobserved.append(p.pid)
            case .gone: gone.append(p.pid)
            }
        }
        return (signal, unverifiable, unobserved, gone)
    }

    /// `kern.bootsessionuuid`: a fresh UUID per boot that, unlike
    /// `kern.boottime`, does not drift when the clock is adjusted.
    static let bootSession: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size + 1)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "" }
        // Bytes up to the first NUL, as C string semantics; CChar is signed
        // on Darwin so map through the bit pattern, never a value conversion.
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    static func kernelState(pid: Int32) -> ProcessLookup {
        guard pid > 0 else { return .absent }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard got == size else {
            // 0 with errno set on failure; a short read is not a usable answer either.
            let err = got == 0 ? errno : EIO
            return err == ESRCH ? .absent : .unreadable(err)
        }
        return .present(ProcessSignalState(
            ppid: Int32(bitPattern: info.pbi_ppid),
            stopped: info.pbi_status == UInt32(SSTOP),
            identity: ProcessIdentity(
                startedAt: Int64(info.pbi_start_tvsec),
                startedAtMicros: Int32(truncatingIfNeeded: info.pbi_start_tvusec),
                bootSession: bootSession
            )
        ))
    }

    /// The same answer as `kernelState`, read from the process table
    /// (sysctl KERN_PROC_PID, as `ps` reads it), which answers for every
    /// user's processes: proc_pidinfo refuses a root process such as `sudo`
    /// or pmset with EPERM. A zombie counts as absent: it has exited and
    /// holds nothing open.
    static func processTableState(pid: Int32) -> ProcessLookup {
        guard pid > 0 else { return .absent }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var entry = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &entry, &size, nil, 0) == 0 else { return .unreadable(errno) }
        // No such pid: success with nothing written.
        guard size == MemoryLayout<kinfo_proc>.stride, entry.kp_proc.p_pid == pid else { return .absent }
        guard entry.kp_proc.p_stat != UInt8(SZOMB) else { return .absent }
        let started = entry.kp_proc.p_starttime
        return .present(ProcessSignalState(
            ppid: entry.kp_eproc.e_ppid,
            stopped: entry.kp_proc.p_stat == UInt8(SSTOP),
            identity: ProcessIdentity(
                startedAt: Int64(started.tv_sec),
                startedAtMicros: Int32(truncatingIfNeeded: started.tv_usec),
                bootSession: bootSession
            )
        ))
    }

    private static func kernelSend(pid: Int32, sig: Int32) -> Int32 {
        guard pid > 0 else { return EINVAL }
        return kill(pid, sig) == 0 ? 0 : errno
    }
}
