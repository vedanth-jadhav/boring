import Foundation

/// Spec section 6 decision table (plus the section 4 lid row), as a pure
/// function plus a small driver.
enum FloorRules {
    /// Why Low Power Mode is being switched on. The strongest cause is
    /// named when several hold: thermal, then battery, then lid.
    enum LowPowerCause: Equatable, Sendable {
        case battery
        case thermal
        case lid
    }

    enum Action: Equatable, Sendable {
        case enableLowPower(LowPowerCause)
        case disableLowPower
        case endSession(EndReason)
    }

    /// Ordered actions for the current inputs.
    ///
    /// - battery below `endFloor` while not charging: end session. 0 never
    ///   matches, so 0 turns the battery end off; Config keeps a non-zero
    ///   `endFloor` below `lowPowerFloor`.
    /// - thermal `critical` (if `thermalRules`): end session
    /// - battery present but unreadable on two consecutive reads while not
    ///   charging, with an end floor set: end session. The floor cannot be
    ///   applied to a level nobody can read, and the Mac is on a battery
    ///   that may be about to die. A desktop has no battery and no floor.
    /// - battery below `lowPowerFloor` while not charging, thermal
    ///   `serious` (if `thermalRules`), or lid closed (if
    ///   `lowPowerOnLidClose`, charging or not): Low Power Mode on
    /// - none of the above while we set Low Power Mode: Low Power Mode off
    ///   ("charger connected", "thermal back to nominal/fair", "lid opened")
    static func evaluate(
        battery: BatteryStatus,
        isCharging: Bool,
        thermal: ProcessInfo.ThermalState,
        lidClosed: Bool,
        lowPowerSetByUs: Bool,
        config: Config
    ) -> [Action] {
        let onBattery = !isCharging
        let percent = battery.percent
        if let p = percent, onBattery, p < config.endFloor {
            return [.endSession(.batteryFloor)]
        }
        if config.thermalRules, thermal == .critical {
            return [.endSession(.thermalCritical)]
        }
        if case let .unreadable(misses) = battery, onBattery, misses >= 2, config.endFloor > 0 {
            return [.endSession(.batteryUnreadable)]
        }
        let cause = lowPowerCause(percent: percent, isCharging: isCharging, thermal: thermal, lidClosed: lidClosed, config: config)
        if let cause, !lowPowerSetByUs { return [.enableLowPower(cause)] }
        if cause == nil, lowPowerSetByUs { return [.disableLowPower] }
        return []
    }

    /// The strongest cause that wants Low Power Mode right now (thermal,
    /// then battery, then lid), or nil when none holds. Independent of
    /// whether the mode is already on, so the driver can track which cause
    /// is keeping it on as the inputs change.
    static func lowPowerCause(
        percent: Int?,
        isCharging: Bool,
        thermal: ProcessInfo.ThermalState,
        lidClosed: Bool,
        config: Config
    ) -> LowPowerCause? {
        if config.thermalRules, thermal == .serious { return .thermal }
        if let p = percent, !isCharging, p < config.lowPowerFloor { return .battery }
        if lidClosed, config.lowPowerOnLidClose { return .lid }
        return nil
    }
}

/// Applies `FloorRules` through the session manager (journal first) and
/// posts the spec section 9 notifications. A lid-caused change is logged
/// but not announced: the user just closed or opened the lid.
///
/// Announce rule for switching the mode off: the disable is announced iff
/// the cause that last held while Caffeine had the mode on was battery or
/// thermal, and silent iff it was the lid. The cause is refreshed on every
/// run while the mode is ours, so a takeover (lid-caused mode kept on by
/// the battery floor, or the reverse) changes which one the disable is
/// attributed to.
@MainActor
struct FloorRuleDriver {
    weak var manager: SessionManager?
    let notifier: any Notifying
    /// The cause that most recently held while Caffeine had the mode on,
    /// so the matching disable knows whether it is announced. Not
    /// journaled: after a relaunch the disable is announced as before.
    private let lastCause = LastCause()

    @MainActor
    private final class LastCause {
        var value: FloorRules.LowPowerCause?
    }

    init(manager: SessionManager, notifier: any Notifying) {
        self.manager = manager
        self.notifier = notifier
    }

    func run(battery: BatteryStatus, isCharging: Bool, thermal: ProcessInfo.ThermalState, lidClosed: Bool) async {
        guard let manager, manager.isActive, !Task.isCancelled else { return }
        let config = manager.config
        let percent = battery.percent
        let actions = FloorRules.evaluate(
            battery: battery,
            isCharging: isCharging,
            thermal: thermal,
            lidClosed: lidClosed,
            lowPowerSetByUs: manager.state.lowPowerSetByUs,
            config: config
        )
        // Track the effective cause while the mode is ours, not only at the
        // enable: another cause may have taken over since.
        if manager.state.lowPowerSetByUs,
           let cause = FloorRules.lowPowerCause(percent: percent, isCharging: isCharging, thermal: thermal, lidClosed: lidClosed, config: config) {
            lastCause.value = cause
        }
        for action in actions {
            guard manager.isActive, !Task.isCancelled else { return }
            switch action {
            case let .enableLowPower(cause):
                guard await manager.setLowPower(true) else { continue }
                lastCause.value = cause
                guard manager.isActive, !Task.isCancelled else { return }
                switch cause {
                case .thermal:
                    notifier.post(title: "Low Power Mode on", body: "Thermal state is serious. Low Power Mode is on until it cools down.")
                case .battery:
                    notifier.post(title: "Low Power Mode on", body: "Battery at \(percent ?? 0)%, below the \(config.lowPowerFloor)% floor.")
                case .lid:
                    Log.info("low power mode on (lid closed)")
                }
            case .disableLowPower:
                if await manager.setLowPower(false) {
                    let cause = lastCause.value
                    lastCause.value = nil
                    guard manager.isActive, !Task.isCancelled else { return }
                    if cause == .lid {
                        Log.info("low power mode off (lid opened)")
                    } else {
                        notifier.post(title: "Low Power Mode off", body: isCharging ? "Charger connected." : "Back above the floor.")
                    }
                }
            case let .endSession(reason):
                await manager.end(reason: reason)
                guard manager.isActive, !Task.isCancelled else { return }
            }
        }
    }
}
