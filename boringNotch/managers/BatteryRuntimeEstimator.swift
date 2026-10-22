import Foundation
import CoreFoundation

/// Projects a sustained electrical load; no persisted samples, training, timer, or service.
/// Charge in mAh / current in mA gives hours. The fuel gauge already accounts for
/// battery aging and unusable charge; a generic voltage curve would count those twice.
struct BatteryRuntimeEstimator {
    private var filteredCurrent: Double?
    private var lastTimestamp: TimeInterval?
    private var lastLowPowerMode: Bool?
    private var baselineStartedAt: TimeInterval?
    private var changeStartedAt: TimeInterval?
    private var changeDirection = 0
    private var changeMeanCurrent: Double?
    private var hasEstablishedBaseline = false

    // Heuristic persistence/noise thresholds; these require discharge-run calibration.
    private static let confirmationSeconds = 180.0
    private static let changeThreshold = 0.25

    mutating func estimate(
        properties: [String: Any],
        isPluggedIn: Bool,
        isCharging: Bool,
        systemTimeToEmpty: Int?,
        systemTimeToFull: Int?,
        timestamp: TimeInterval,
        lowPowerMode: Bool = false
    ) -> (empty: Int, full: Int) {
        let data = properties["BatteryData"] as? [String: Any] ?? [:]
        // Hardware charge-time estimates include the constant-voltage taper and thermal limits.
        // Never divide adapter nameplate watts into battery capacity to predict charging.
        if isPluggedIn || isCharging {
            reset()
            let full = isCharging ? Self.validMinutes(systemTimeToFull)
                ?? Self.validMinutes(properties["AvgTimeToFull"] as? Int) ?? -1 : 0
            return (0, full)
        }
        let fallback = Self.validMinutes(systemTimeToEmpty)
            ?? Self.validMinutes(properties["AvgTimeToEmpty"] as? Int)
            ?? Self.validMinutes(data["AvgTimeToEmpty"] as? Int) ?? -1

        // Reject stale registry data after sleep and mixed snapshots during cable transitions.
        if let updated = Self.positiveNumber(properties["UpdateTime"]),
           timestamp - updated > 180 || updated - timestamp > 5 {
            reset()
            return (-1, 0)
        }
        if let connected = properties["ExternalConnected"] as? Bool, connected {
            reset()
            return (-1, 0)
        }
        guard let charge = Self.remainingCharge(properties, data: data) else {
            reset()
            return (fallback, 0)
        }
        if charge == 0 {
            reset()
            return (0, 0)
        }
        let average = Self.dischargeCurrent(properties["Amperage"])
        let instant = Self.dischargeCurrent(properties["InstantAmperage"])
        guard let measurement = instant ?? average else {
            reset()
            return (fallback, 0)
        }
        // A positive instantaneous current contradicts discharging even when the average lags.
        if let signed = Self.signedCurrent(properties["InstantAmperage"]), signed >= 0 {
            reset()
            return (-1, 0)
        }
        let sampleTime = Self.positiveNumber(properties["UpdateTime"]) ?? timestamp
        let elapsed = lastTimestamp.map { sampleTime - $0 } ?? .infinity
        if lastLowPowerMode != lowPowerMode || elapsed < 0 || elapsed > 180 {
            reset()
        }
        if let current = filteredCurrent, elapsed > 0, elapsed <= 180 {
            let relativeChange = (measurement - current) / max(current, 5)
            if abs(relativeChange) > Self.changeThreshold {
                let direction = relativeChange > 0 ? 1 : -1
                if changeDirection != direction {
                    changeStartedAt = sampleTime
                    changeDirection = direction
                    changeMeanCurrent = measurement
                } else if let start = changeStartedAt, let mean = changeMeanCurrent, sampleTime > start {
                    changeMeanCurrent = mean + (measurement - mean) * min(1, elapsed / (sampleTime - start))
                }
                // Bursts contribute slowly to the long-run drain, so recurring work still counts.
                let slowGain = 1 - exp(-elapsed / 1800)
                filteredCurrent = current + slowGain * (measurement - current)
                // Adopting an entirely new load needs three minutes of fresh evidence.
                if let start = changeStartedAt, sampleTime - start >= Self.confirmationSeconds {
                    filteredCurrent = changeMeanCurrent ?? measurement
                    changeStartedAt = nil
                    changeDirection = 0
                    changeMeanCurrent = nil
                }
            } else {
                changeStartedAt = nil
                changeDirection = 0
                changeMeanCurrent = nil
                let gain = 1 - exp(-elapsed / 300)
                filteredCurrent = current + gain * (measurement - current)
            }
        } else if filteredCurrent == nil {
            filteredCurrent = average ?? measurement
            baselineStartedAt = sampleTime
        }
        lastTimestamp = sampleTime
        lastLowPowerMode = lowPowerMode
        guard let current = filteredCurrent, let start = baselineStartedAt,
              sampleTime - start >= Self.confirmationSeconds else { return (-1, 0) }
        if !hasEstablishedBaseline {
            guard changeStartedAt == nil else { return (-1, 0) }
            hasEstablishedBaseline = true
        }
        let minutes = charge / current * 60
        // Near-zero loads and broken gauges must not produce multi-day or overflowing values.
        guard minutes.isFinite, minutes > 0, minutes <= 48 * 60 else { return (-1, 0) }
        return (max(1, Int(minutes.rounded())), 0)
    }

    private mutating func reset() {
        filteredCurrent = nil
        lastTimestamp = nil
        lastLowPowerMode = nil
        baselineStartedAt = nil
        changeStartedAt = nil
        changeDirection = 0
        changeMeanCurrent = nil
        hasEstablishedBaseline = false
    }

    private static func remainingCharge(_ properties: [String: Any], data: [String: Any]) -> Double? {
        // Keep each capacity pair in its native units. CurrentCapacity/MaxCapacity on Apple
        // silicon are percentages, whereas nested RemainingCapacity is a physical mAh value.
        let pairs: [(Any?, Any?)] = [
            (properties["AppleRawCurrentCapacity"], properties["AppleRawMaxCapacity"]),
            (data["RemainingCapacity"], data["FullChargeCapacity"]),
            (properties["CurrentCapacity"], properties["MaxCapacity"])
        ]
        for (remainingValue, fullValue) in pairs {
            guard let full = positiveNumber(fullValue), full > 100, full <= 100_000,
                  let remaining = number(remainingValue), remaining >= 0, remaining <= full else { continue }
            return remaining
        }
        return nil
    }

    static func positiveNumber(_ value: Any?) -> Double? {
        guard let value = number(value), value > 0 else { return nil }
        return value
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func signedCurrent(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, Self.number(value) != nil else { return nil }
        // Some drivers expose signed mA as unsigned 32/64-bit two's-complement numbers.
        var signed = number.int64Value
        if signed > Int64(Int32.max), signed <= Int64(UInt32.max) {
            signed = Int64(Int32(bitPattern: UInt32(signed)))
        }
        guard abs(Double(signed)) <= 100_000 else { return nil }
        return Double(signed)
    }

    private static func dischargeCurrent(_ value: Any?) -> Double? {
        guard let current = signedCurrent(value), current <= -5 else { return nil }
        return -current
    }

    private static func validMinutes(_ value: Int?) -> Int? {
        guard let value, value > 0, value <= 48 * 60 else { return nil }
        return value
    }
}
