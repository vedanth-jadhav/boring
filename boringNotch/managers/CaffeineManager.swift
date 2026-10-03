import Foundation
import IOKit.pwr_mgt

/// One service for all callers. Acquisition is idempotent per owner; release
/// removes only that owner's lease. Idle assertions never override explicit sleep.
@MainActor
final class CaffeineManager: FocusPowerManaging {
    enum Owner: String, Hashable {
        case lockScreen
        case focusSession

        var reason: String {
            switch self {
            case .lockScreen: return "Boring Notch: lock-screen music"
            case .focusSession: return "Boring Notch: timed Caffeine session"
            }
        }
    }

    static let shared = CaffeineManager()
    private struct Lease { var deadline: Date? }
    private var leases: [Owner: Lease] = [:]
    private var systemAssertion: IOPMAssertionID?
    private var displayAssertion: IOPMAssertionID?
    private(set) var lastError: IOReturn = kIOReturnSuccess
    var owners: Set<Owner> { Set(leases.keys) }

    @discardableResult
    func acquire(owner: Owner, until deadline: Date? = nil) -> Bool {
        guard deadline == nil || deadline! > Date() else { return false }
        let previous = leases[owner]
        leases[owner] = Lease(deadline: deadline)
        guard reconcile() else {
            leases[owner] = previous
            _ = reconcile()
            return false
        }
        return true
    }

    func release(owner: Owner) {
        leases.removeValue(forKey: owner)
        _ = reconcile()
    }

    func releaseAll() {
        leases.removeAll()
        releaseAssertions()
    }

    /// Validate on wake and clock changes before updating the kernel lease.
    @discardableResult
    func reconcile() -> Bool {
        let now = Date()
        leases = leases.filter { $0.value.deadline.map { $0 > now } ?? true }
        guard !leases.isEmpty else {
            releaseAssertions()
            return true
        }
        let reason = leases.keys.sorted { $0.rawValue < $1.rawValue }.map(\.reason).joined(separator: "; ")
        let indefinite = leases.values.contains { $0.deadline == nil }
        let timeout = indefinite ? 0 : max(0.001, (leases.values.compactMap(\.deadline).max() ?? now).timeIntervalSince(now))
        // Acquire replacements before releasing old assertions: changing owners
        // cannot introduce a brief window where idle sleep is allowed.
        var system: IOPMAssertionID = 0
        var display: IOPMAssertionID = 0
        lastError = create(type: kIOPMAssertionTypePreventUserIdleSystemSleep, reason: reason, timeout: timeout, id: &system)
        guard lastError == kIOReturnSuccess else { return false }
        lastError = create(type: kIOPMAssertionTypePreventUserIdleDisplaySleep, reason: reason, timeout: timeout, id: &display)
        guard lastError == kIOReturnSuccess else {
            IOPMAssertionRelease(system)
            return false
        }
        releaseAssertions()
        systemAssertion = system
        displayAssertion = display
        return true
    }

    private func create(type: String, reason: String, timeout: TimeInterval, id: inout IOPMAssertionID) -> IOReturn {
        IOPMAssertionCreateWithDescription(type as CFString, reason as CFString,
            reason as CFString, reason as CFString, nil, timeout,
            kIOPMAssertionTimeoutActionRelease as CFString, &id)
    }

    private func releaseAssertions() {
        if let systemAssertion { IOPMAssertionRelease(systemAssertion) }
        if let displayAssertion { IOPMAssertionRelease(displayAssertion) }
        systemAssertion = nil
        displayAssertion = nil
    }
}
