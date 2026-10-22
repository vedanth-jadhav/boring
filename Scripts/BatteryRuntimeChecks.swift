import Foundation
import IOKit

@main struct BatteryRuntimeChecks {
    static var checks = 0
    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
        print("PASS \(message)")
    }
    static func properties(charge: Double = 3000, full: Double = 6000, current: Int = -1000) -> [String: Any] {
        ["CurrentCapacity": 50, "MaxCapacity": 100,
         "BatteryData": ["RemainingCapacity": charge, "FullChargeCapacity": full],
         "Amperage": current, "InstantAmperage": current]
    }
    static func sample(_ filter: inout BatteryRuntimeEstimator, _ p: [String: Any], _ time: Double,
                       lowPower: Bool = false, plugged: Bool = false, charging: Bool = false,
                       fallback: Int? = nil, full: Int? = nil) -> (empty: Int, full: Int) {
        filter.estimate(properties: p, isPluggedIn: plugged, isCharging: charging,
                        systemTimeToEmpty: fallback, systemTimeToFull: full, timestamp: time, lowPowerMode: lowPower)
    }
    static func steady(_ p: [String: Any], fallback: Int? = nil) -> Int {
        var filter = BatteryRuntimeEstimator()
        var value = -1
        for time in stride(from: 1000.0, through: 1180.0, by: 60) {
            value = sample(&filter, p, time, fallback: fallback).empty
        }
        return value
    }
    static func warmed(current: Int = -1000) -> BatteryRuntimeEstimator {
        var filter = BatteryRuntimeEstimator()
        for time in stride(from: 1000.0, through: 1180.0, by: 60) {
            _ = sample(&filter, properties(current: current), time)
        }
        return filter
    }
    static func main() {
        require(steady(properties()) == 180, "3000 mAh / 1000 mA = 180 minutes after baseline settles")
        require(steady(properties(current: -2000)) == 90, "double sustained electrical load halves runtime")
        require(steady(properties(charge: 1500)) == 90, "half usable charge halves runtime")
        require(steady(properties(charge: 300, full: 600)) == 18, "worn battery uses actual capacity")
        require(steady(["CurrentCapacity": 50, "MaxCapacity": 100, "Amperage": -1000], fallback: 123) == 123,
                "percentage units never masquerade as mAh")
        require(steady(["CurrentCapacity": 3000, "MaxCapacity": 6000, "Amperage": -1000]) == 180,
                "legacy Intel physical capacities supported")
        require(steady(["AppleRawCurrentCapacity": 3000, "AppleRawMaxCapacity": 6000, "Amperage": -1000]) == 180,
                "raw Apple capacity pair supported")
        require(steady(properties(charge: 0)) == 0, "empty battery has zero runtime")
        require(steady(properties(charge: 7000), fallback: 110) == 110, "impossible capacity falls back")
        require(steady(properties(charge: .nan)) == -1, "nonfinite capacities rejected")
        require(steady(properties(current: 0)) == -1, "zero current cannot produce infinity")
        require(steady(properties(current: -1)) == -1, "near-zero current stays unknown")
        require(steady(properties(current: Int.min)) == -1, "extreme signed integers cannot overflow")
        require(steady(properties(current: -10)) == -1, "unphysical multiday projection stays unknown")
        var p = properties()
        p["Amperage"] = NSNumber(value: UInt32(bitPattern: -1000))
        p["InstantAmperage"] = NSNumber(value: UInt64(bitPattern: -1000))
        require(steady(p) == 180, "unsigned two's-complement driver currents decoded")
        p = properties(); p["InstantAmperage"] = 1000
        require(steady(p, fallback: 180) == -1, "contradictory current after cable transition stays unknown")
        p = properties(); p["UpdateTime"] = 100
        require(steady(p, fallback: 180) == -1, "stale sleep telemetry rejected")
        p["UpdateTime"] = 2000
        require(steady(p) == -1, "future telemetry rejected")
        p = properties(); p["ExternalConnected"] = true
        require(steady(p) == -1, "mixed AC and battery snapshot rejected")
        require(steady([:], fallback: 65535) == -1, "firmware unknown sentinel rejected")
        require(steady(["BatteryData": ["AvgTimeToEmpty": 150]]) == 150, "nested firmware fallback supported")
        p = properties(); p["Amperage"] = true; p["InstantAmperage"] = false
        require(steady(p, fallback: 123) == 123, "boolean telemetry rejected")
        p = properties(); p["AppleRawCurrentCapacity"] = 7000; p["AppleRawMaxCapacity"] = 6000
        require(steady(p) == 180, "invalid raw pair falls back to valid nested physical pair")

        var filter = BatteryRuntimeEstimator()
        require(sample(&filter, properties(), 1000).empty == -1, "startup has no falsely confident instant estimate")
        require(sample(&filter, properties(), 1060).empty == -1, "one minute is insufficient to establish baseline")
        _ = sample(&filter, properties(), 1120)
        require(sample(&filter, properties(), 1180).empty == 180, "three-minute stable baseline becomes available")
        for duration in [1, 30, 60, 120] {
            var burstFilter = warmed(current: -600)
            var charge = 3000.0
            var previousLoad = 600.0
            var minimum = 300
            var maximumError = 0
            // Spend real charge during the burst, then return to the original load.
            for second in 1...(duration + 60) {
                charge -= previousLoad / 3600
                let load = second <= duration ? 1500 : 600
                let minutes = sample(&burstFilter, properties(charge: charge, current: -load), 1180 + Double(second)).empty
                let expected = Int((charge / 600 * 60).rounded())
                maximumError = max(maximumError, abs(minutes - expected))
                minimum = min(minimum, minutes)
                previousLoad = Double(load)
            }
            print("SIMULATED \(duration)-second burst: lowest displayed=\(minimum) min from a 300-min baseline")
            require(maximumError <= max(2, duration / 2) && minimum > (duration <= 60 ? 280 : 260),
                    "\(duration)-second server spike spends charge without turning 5 hours into 2")
        }
        filter = warmed()
        _ = sample(&filter, properties(current: -4000), 1190)
        var beforeConfirmation = -1
        for t in stride(from: 1200.0, through: 1360.0, by: 10) {
            beforeConfirmation = sample(&filter, properties(current: -4000), t).empty
        }
        require(beforeConfirmation > 135, "large change contributes gradually before three-minute confirmation")
        require(sample(&filter, properties(current: -4000), 1370).empty == 45,
                "sustained fourfold load becomes the new baseline")
        var confirmationFilter = warmed()
        for t in stride(from: 1190.0, through: 1360.0, by: 10) {
            _ = sample(&confirmationFilter, properties(current: -2000), t)
        }
        let confirmationSpike = sample(&confirmationFilter, properties(current: -8000), 1370).empty
        require(confirmationSpike >= 70, "one spike at the confirmation boundary cannot become the new baseline")
        require(sample(&filter, properties(), 1700).empty == -1, "sleep gap discards baseline and restarts calculation")
        require(sample(&filter, properties(), 1600).empty == -1, "clock rollback restarts calculation")
        filter = warmed()
        require(sample(&filter, properties(), 1190, lowPower: true).empty == -1, "low power mode resets baseline")
        filter = warmed()
        let plugged = sample(&filter, properties(), 1190, plugged: true, full: 90)
        require(plugged.empty == 0 && plugged.full == 0, "charging hold has no invented countdown")
        require(sample(&filter, properties(current: -2000), 1200).empty == -1, "unplugging restarts baseline collection")
        let charging = sample(&filter, ["AvgTimeToFull": 70], 1304, plugged: true, charging: true, full: 95)
        require(charging.empty == 0 && charging.full == 95, "calibrated charging estimate preserves taper")
        let unknownCharging = sample(&filter, ["AvgTimeToFull": 65535], 1305, plugged: true, charging: true, full: -1)
        require(unknownCharging.full == -1, "unknown charging estimate remains calculating")

        filter = warmed()
        // Averaged hardware current can lag behind the instant return to normal.
        for t in stride(from: 1190.0, through: 1240.0, by: 10) {
            _ = sample(&filter, properties(current: -4000), t)
        }
        p = properties(); p["Amperage"] = -4000
        var recovered = -1
        for t in stride(from: 1250.0, through: 1430.0, by: 10) { recovered = sample(&filter, p, t).empty }
        require(recovered >= 160, "lagging driver average cannot prolong a finished spike")
        filter = warmed()
        var recurringMinimum = 180
        for second in stride(from: 10, through: 1200, by: 10) {
            let load = second % 180 < 60 ? -4000 : -1000
            recurringMinimum = min(recurringMinimum, sample(&filter, properties(current: load), 1180 + Double(second)).empty)
        }
        require(recurringMinimum < 175 && recurringMinimum > 100, "recurring short bursts gradually contribute without being declared a sustained fourfold load")
        filter = warmed()
        p = properties(current: -4000); p["UpdateTime"] = 1190
        _ = sample(&filter, p, 1190)
        for time in stride(from: 1200.0, through: 1360.0, by: 10) { _ = sample(&filter, p, time) }
        p["UpdateTime"] = 1250
        require(sample(&filter, p, 1360).empty > 160, "repeated callbacks for one sensor reading cannot confirm a load change")
        filter = BatteryRuntimeEstimator()
        _ = sample(&filter, properties(current: -4000), 1000)
        var startup = -1
        for t in stride(from: 1060.0, through: 1180.0, by: 60) { startup = sample(&filter, properties(), t).empty }
        require(startup == -1, "launching during spike stays calculating while initial baseline is challenged")
        require(sample(&filter, properties(), 1240).empty == 180, "startup spike clears after normal load is confirmed")
        func cadence(_ interval: Double) -> Int {
            var f = warmed()
            var value = 0
            for t in stride(from: 1180 + interval, through: 1240, by: interval) {
                value = sample(&f, properties(current: -1200), t).empty
            }
            return value
        }
        require(cadence(1) == cadence(10), "ordinary smoothing independent of callback frequency")
        print("\(checks) battery runtime regression checks passed")
        liveCheck()
    }
    static func liveCheck() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { print("Live telemetry unavailable"); return }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let p = properties?.takeRetainedValue() as? [String: Any] else { return }
        var filter = BatteryRuntimeEstimator()
        let result = sample(&filter, p, Date.now.timeIntervalSince1970,
                            plugged: p["ExternalConnected"] as? Bool ?? false,
                            charging: p["IsCharging"] as? Bool ?? false)
        print("LIVE startup: empty=\(result.empty) min, full=\(result.full) min; -1 means calculating (not an accuracy benchmark)")
    }
}
