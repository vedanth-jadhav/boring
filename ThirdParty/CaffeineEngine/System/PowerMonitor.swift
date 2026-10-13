import Foundation
import IOKit
import IOKit.ps

/// What the power source list says about the built-in battery. A desktop
/// has none and the battery floors do not apply; a laptop whose battery
/// cannot be read is a different state, because the end floor cannot be
/// applied there either and the session must not run blind (spec section 6).
enum BatteryStatus: Equatable, Sendable {
    /// No internal battery.
    case none
    /// Battery present and its level read.
    case percent(Int)
    /// Battery present but its level not read: the power source list was
    /// unavailable, had no internal battery entry, or the entry had no usable
    /// capacity. `misses` counts consecutive reads in this state, capped at
    /// 2; one is tolerated as a transient IOKit miss.
    case unreadable(misses: Int)

    var percent: Int? {
        if case let .percent(p) = self { return p }
        return nil
    }
}

/// Spec section 6 event sources: `IOPSNotificationCreateRunLoopSource` for
/// battery changes and `ProcessInfo.thermalStateDidChangeNotification`.
/// Watts are read from `AppleSmartBattery` only when `instantWatts()` is
/// called (the popover opening), never polled. While the battery is
/// unreadable the list is re-read every `recheckDelay`, since IOKit sends
/// no event for a read that keeps failing.
@MainActor
final class PowerMonitor {
    typealias Reader = @Sendable () -> (battery: BatteryStatus, charging: Bool)

    private(set) var battery: BatteryStatus = .none
    var percent: Int? { battery.percent }
    /// True when on AC power or actively charging. The floor rules treat
    /// "charger connected" as the undo condition (spec section 6).
    private(set) var isCharging: Bool = false
    private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    /// Called on the main actor after any battery or thermal change.
    var onChange: (() -> Void)?

    private let reader: Reader
    private let recheckDelay: Duration
    private var source: CFRunLoopSource?
    private var thermalObserver: NSObjectProtocol?
    private var running = false
    private var recheck: Task<Void, Never>?

    /// `reader` and `recheckDelay` are injection points for tests; the
    /// defaults read IOKit and wait 30 s between re-reads of an unreadable
    /// battery.
    init(reader: @escaping Reader = { PowerMonitor.readBattery() }, recheckDelay: Duration = .seconds(30)) {
        self.reader = reader
        self.recheckDelay = recheckDelay
    }

    func start() {
        guard !running else { return }
        running = true
        // Misses from before a stop are not consecutive with this run.
        battery = .none
        refreshBattery()
        thermalState = ProcessInfo.processInfo.thermalState

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let s = IOPSNotificationCreateRunLoopSource(Self.callback, refcon)?.takeRetainedValue() {
            source = s
            CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        } else {
            Log.error("power monitor: IOPSNotificationCreateRunLoopSource failed")
        }

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.handleThermal() }
        }
        Log.info("power monitor started (battery \(Self.describe(battery)), \(isCharging ? "charging" : "on battery"), thermal \(Self.name(thermalState)))")
    }

    func stop() {
        running = false
        recheck?.cancel()
        recheck = nil
        if let s = source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes)
            source = nil
        }
        if let o = thermalObserver {
            NotificationCenter.default.removeObserver(o)
            thermalObserver = nil
        }
    }

    /// Re-read the power source list synchronously for the menu and the
    /// startup snapshot. Cheap. Misses are not counted here: only the event
    /// path and the recheck count them, so a menu opened during a transient
    /// miss cannot be the second one, and the count never moves without
    /// `handleBattery` seeing the move and running the floor rules. A battery
    /// that stays unreadable keeps its count; one that has just become
    /// unreadable gets a recheck if none is pending.
    func refreshBattery() {
        let snap = reader()
        if case .unreadable = snap.battery, case .unreadable = battery {
            // Keep the count.
        } else {
            battery = snap.battery
        }
        isCharging = snap.charging
        if recheck == nil { scheduleRecheckIfUnreadable() }
    }

    /// The read behind IOKit events and the recheck. A miss after a miss
    /// counts up, so the floor rules can tell one transient failure from a
    /// battery that stays unreadable.
    private func readCountingMisses() {
        let snap = reader()
        if case .unreadable = snap.battery, case let .unreadable(misses) = battery {
            battery = .unreadable(misses: min(misses + 1, 2))
        } else {
            battery = snap.battery
        }
        isCharging = snap.charging
        scheduleRecheckIfUnreadable()
    }

    /// Signed watts: negative while discharging, positive while charging.
    /// nil when there is no AppleSmartBattery (desktop) or a key is missing.
    nonisolated func instantWatts() -> Double? {
        Self.readInstantWatts()
    }

    static func name(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    // MARK: Reads

    nonisolated static func readBattery() -> (battery: BatteryStatus, charging: Bool) {
        var sources: [[String: Any]]?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            sources = list.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
        }
        return classify(sources: sources, hasBatteryService: hasBatteryService, externalPowerConnected: externalPowerConnected)
    }

    /// The power source descriptions as `BatteryStatus`. `sources` is nil
    /// when the list itself could not be read. Without an internal battery
    /// entry, `hasBatteryService` decides between a desktop (no battery) and
    /// a laptop whose battery is not reported, and on that laptop
    /// `externalPowerConnected` decides charger or battery; both are only
    /// consulted then. When the charger state cannot be read either, the
    /// laptop is taken to be on battery: the two-miss rule then ends the
    /// session, which costs a restart, whereas taking it to be on a charger
    /// would hold sleep with no floor on a battery that may be draining.
    nonisolated static func classify(
        sources: [[String: Any]]?,
        hasBatteryService: () -> Bool,
        externalPowerConnected: () -> Bool?
    ) -> (battery: BatteryStatus, charging: Bool) {
        for desc in sources ?? [] {
            guard desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let onAC = desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let current = desc[kIOPSCurrentCapacityKey] as? Int
            let max = desc[kIOPSMaxCapacityKey] as? Int
            guard let current, let max, max > 0 else {
                return (.unreadable(misses: 1), onAC || charging)
            }
            return (.percent(Int((Double(current) / Double(max) * 100).rounded())), onAC || charging)
        }
        guard hasBatteryService() else { return (.none, false) }
        return (.unreadable(misses: 1), externalPowerConnected() ?? false)
    }

    /// Whether the machine has a built-in battery at all, from the I/O
    /// Registry rather than the power source list that just failed.
    nonisolated static func hasBatteryService() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    /// `ExternalConnected` from the `AppleSmartBattery` service: the battery
    /// driver's own view of whether a charger is attached, read from the I/O
    /// Registry rather than the power source list that just failed. nil when
    /// the service or the property cannot be read.
    nonisolated static func externalPowerConnected() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "ExternalConnected" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    nonisolated static func readInstantWatts() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func int(_ key: String) -> Int64? {
            guard let v = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
            return (v as? NSNumber)?.int64Value
        }
        guard var amperage = int("InstantAmperage"), let voltage = int("Voltage") else { return nil }
        // Some firmware reports a negative (discharging) current as a 32-bit
        // two's complement value stored in a wider integer.
        if amperage > Int64(Int32.max), amperage <= Int64(UInt32.max) {
            amperage -= Int64(UInt32.max) + 1
        }
        return Double(amperage) * Double(voltage) / 1_000_000
    }

    // MARK: Private

    private static let callback: IOPowerSourceCallbackType = { refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<PowerMonitor>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { monitor.handleBattery() }
    }

    private func handleBattery() {
        let before = (battery, isCharging)
        readCountingMisses()
        if before != (battery, isCharging) {
            Log.info("battery \(Self.describe(battery)) \(isCharging ? "charging" : "on battery")")
            onChange?()
        }
    }

    /// IOKit reports changes, not a read that keeps failing: while the
    /// battery is unreadable, re-read it after `recheckDelay` so the second
    /// miss (or the recovery) is seen. Only while started; `stop()` cancels.
    private func scheduleRecheckIfUnreadable() {
        recheck?.cancel()
        recheck = nil
        guard running, case .unreadable = battery else { return }
        recheck = Task { @MainActor [weak self, recheckDelay] in
            try? await Task.sleep(for: recheckDelay)
            guard !Task.isCancelled else { return }
            self?.handleBattery()
        }
    }

    static func describe(_ battery: BatteryStatus) -> String {
        switch battery {
        case .none: "n/a (no battery)"
        case let .percent(p): "\(p)%"
        case let .unreadable(misses): "unreadable (miss \(misses))"
        }
    }

    private func handleThermal() {
        let now = ProcessInfo.processInfo.thermalState
        guard now != thermalState else { return }
        thermalState = now
        Log.info("thermal state \(Self.name(now))")
        onChange?()
    }
}
