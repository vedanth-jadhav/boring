import Cocoa
import Defaults
import Foundation
import IOKit.ps
import SwiftUI

/// A view model that manages and monitors the battery status of the device
final class BatteryStatusViewModel: ObservableObject {
    private var wasCharging: Bool = false
    private var powerSourceChangedCallback: IOPowerSourceCallbackType?
    private var runLoopSource: Unmanaged<CFRunLoopSource>?

    @Published private(set) var levelBattery: Float = 0.0
    @Published private(set) var maxCapacity: Float?
    @Published private(set) var isPluggedIn: Bool = false
    @Published private(set) var isCharging: Bool = false
    @Published private(set) var isInLowPowerMode: Bool = false
    @Published private(set) var isInitial: Bool = false
    @Published private(set) var timeToFullCharge: Int = 0
    @Published private(set) var timeToDischarge: Int = 0
    @Published private(set) var maxAdapterWatts: Int = 0
    @Published private(set) var lastStatus: LastStatus = .plugged(false)

    enum LastStatus: Equatable {
        case plugged(Bool)
        case lowPower(Bool)
        case charging(isCharging: Bool, level: Float)
    }

    var statusText: LocalizedStringKey {
        switch lastStatus {
        case .plugged(let plugged):
            return LocalizedStringKey(plugged ? "Plugged In" : "Unplugged")
        case .lowPower(let enabled):
            let key = enabled ? "Low Power: On" : "Low Power: Off"
            return LocalizedStringKey(key)
        case .charging(let isCharging, let level):
            if isCharging {
                return LocalizedStringKey("Charging battery")
            }
            if level < 100 {
                return LocalizedStringKey("Not charging")
            }
            return LocalizedStringKey("Full charge")
        }
    }

    private let managerBattery: BatteryActivityManager
    private var managerBatterySnapshotId: Int?

    static let shared = BatteryStatusViewModel()

    /// Initializes the view model with a given BoringViewModel instance
    /// - Parameter vm: The BoringViewModel instance
    init(manager: BatteryActivityManager = .shared, initialBatteryInfo: BatteryInfo? = nil) {
        managerBattery = manager
        setupPowerStatus(initialBatteryInfo)
        setupMonitor()
    }

    /// Sets up the initial power status by fetching battery information
    private func setupPowerStatus(_ initialBatteryInfo: BatteryInfo?) {
        let batteryInfo = initialBatteryInfo ?? managerBattery.initializeBatteryInfo()
        updateBatteryInfo(batteryInfo)
    }

    /// Sets up the monitor to observe battery events
    private func setupMonitor() {
        managerBatterySnapshotId = managerBattery.addSnapshotObserver { [weak self] batteryInfo in
            self?.handleBatterySnapshot(batteryInfo)
        }
    }

    /// Applies one IOKit sample coherently, then requests at most one expansion.
    private func handleBatterySnapshot(_ batteryInfo: BatteryInfo) {
        let sourceChanged = isPluggedIn != batteryInfo.isPluggedIn
        let chargingChanged = isCharging != batteryInfo.isCharging
        let lowPowerChanged = isInLowPowerMode != batteryInfo.isInLowPowerMode

        withAnimation {
            levelBattery = batteryInfo.currentCapacity
            isPluggedIn = batteryInfo.isPluggedIn
            isCharging = batteryInfo.isCharging
            isInLowPowerMode = batteryInfo.isInLowPowerMode
            timeToFullCharge = batteryInfo.timeToFullCharge
            timeToDischarge = batteryInfo.timeToDischarge
            maxCapacity = batteryInfo.maxCapacity
            maxAdapterWatts = batteryInfo.maxAdapterWatts

            if sourceChanged {
                lastStatus = .plugged(batteryInfo.isPluggedIn)
            }
            if chargingChanged {
                lastStatus = .charging(isCharging: batteryInfo.isCharging, level: batteryInfo.currentCapacity)
            }
            if lowPowerChanged {
                lastStatus = .lowPower(batteryInfo.isInLowPowerMode)
            }
        }

        if sourceChanged || chargingChanged || lowPowerChanged {
            notifyImportanChangeStatus()
        }
    }

    /// Updates the battery information with the given BatteryInfo instance
    /// - Parameter batteryInfo: The BatteryInfo instance containing the battery data
    private func updateBatteryInfo(_ batteryInfo: BatteryInfo) {
        withAnimation {
            self.levelBattery = batteryInfo.currentCapacity
            self.isPluggedIn = batteryInfo.isPluggedIn
            self.isCharging = batteryInfo.isCharging
            self.isInLowPowerMode = batteryInfo.isInLowPowerMode
            self.timeToFullCharge = batteryInfo.timeToFullCharge
            self.timeToDischarge = batteryInfo.timeToDischarge
            self.maxCapacity = batteryInfo.maxCapacity
            self.maxAdapterWatts = batteryInfo.maxAdapterWatts
            self.lastStatus = .plugged(batteryInfo.isPluggedIn)
        }
    }

    /// Notifies important changes in the battery status with an optional delay
    /// - Parameter delay: The delay before notifying the change, default is 0.0
    private func notifyImportanChangeStatus(delay: Double = 0.0) {
        Task { [delay] in
            try? await Task.sleep(for: .seconds(delay))
            NotchUIEventBus.events.send(.expandingView(type: .battery))
        }
    }

    deinit {
        Log.battery.debug("🔌 Cleaning up battery monitoring...")
        if let managerBatterySnapshotId {
            managerBattery.removeSnapshotObserver(byId: managerBatterySnapshotId)
        }
    }
}
