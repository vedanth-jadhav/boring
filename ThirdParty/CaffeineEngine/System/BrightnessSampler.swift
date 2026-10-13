import CoreGraphics
import Foundation

/// The last display and keyboard brightness values that were read while
/// they could be trusted (spec section 4).
struct BrightnessSample: Equatable, Sendable {
    var display: Float?
    var keyboard: Float?
    var takenAt: Date
}

/// Seconds since the last keyboard, mouse or trackpad event, from public
/// CoreGraphics; needs no permission.
enum UserInput {
    /// `kCGAnyInputEventType` (~0) is not importable in Swift, so it is
    /// spelled out. `CGEventType` is an open enum: any raw value is valid.
    static let anyInputEventType = CGEventType(rawValue: UInt32.max)!

    static func secondsSinceLastInput() -> Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInputEventType)
    }
}

/// Remembers the user's real brightness values so a lid close that finds the
/// panel idle-dimmed, asleep, rescaled by Low Power Mode or already dropped
/// by auto-brightness under the closing lid (where the display reads a value
/// that is not the user's, and a suppressed keyboard reads 0) still journals
/// something worth restoring. A reading is trusted when the user touched
/// the machine less than `maxIdle` seconds ago (the idle dim never starts
/// within 30 s of input) and the device is not being held down by macOS
/// itself.
@MainActor
final class BrightnessSampler {
    private let display: any DisplayDimming
    private let keyboard: any KeyboardBacklighting
    private let idleSeconds: @Sendable () -> Double
    private let clock: @Sendable () -> Date
    private let maxIdle: Double

    /// While true, display readings are not taken. Either the journal on
    /// disk says Caffeine's own Low Power Mode is on and the panel reads
    /// the mode's rescaled value, or one on its way back, not the user's,
    /// so the sample taken just before the mode went on, or the level
    /// written after it, is kept; or the journal holds a saved display
    /// brightness, so the panel reads the 0 a lid close left or a level
    /// not yet decided. Wired to the session journal by `follow`.
    var displayHeld: () -> Bool = { false }
    /// The same for the keyboard backlight: true while the journal holds a
    /// saved keyboard brightness.
    var keyboardHeld: () -> Bool = { false }

    private(set) var last: BrightnessSample?

    init(
        display: any DisplayDimming,
        keyboard: any KeyboardBacklighting,
        idleSeconds: @escaping @Sendable () -> Double,
        clock: @escaping @Sendable () -> Date = { Date() },
        maxIdle: Double = 30
    ) {
        self.display = display
        self.keyboard = keyboard
        self.idleSeconds = idleSeconds
        self.clock = clock
        self.maxIdle = maxIdle
    }

    /// True when a display reading taken now is the user's value: recent
    /// input and the panel is awake.
    var displayReadIsTrusted: Bool {
        idleSeconds() < maxIdle && !display.isAsleep()
    }

    /// Same for the keyboard: recent input and the backlight is neither
    /// suppressed by display sleep nor idle-dimmed.
    var keyboardReadIsTrusted: Bool {
        idleSeconds() < maxIdle && !keyboard.isSuppressedOrDimmed()
    }

    /// Reads whichever of the two values is trustworthy right now and merges
    /// them into `last` per field, so a trusted display read next to an
    /// untrusted keyboard keeps the earlier keyboard value. A read that
    /// throws, or a keyboard without a backlight, is skipped. Returns what
    /// was taken now; nil when nothing was.
    @discardableResult
    func sample() -> BrightnessSample? {
        var taken = BrightnessSample(display: nil, keyboard: nil, takenAt: clock())
        if !displayHeld(), displayReadIsTrusted, let value = try? display.readBrightness() {
            taken.display = value
        }
        if !keyboardHeld(), keyboardReadIsTrusted, let value = (try? keyboard.readBrightness()) ?? nil {
            taken.keyboard = value
        }
        guard taken.display != nil || taken.keyboard != nil else { return nil }
        merge(taken)
        return taken
    }

    /// A level known to be the user's without a reading of its own: one
    /// written from the journal, or one that a kept value's trusted
    /// reading found set since. Taken even while the device is held, since
    /// the hold only keeps out readings that may not be the user's.
    func record(display: Float?, keyboard: Float?) {
        guard display != nil || keyboard != nil else { return }
        merge(BrightnessSample(display: display, keyboard: keyboard, takenAt: clock()))
    }

    private func merge(_ taken: BrightnessSample) {
        var merged = last ?? taken
        merged.takenAt = taken.takenAt
        if let value = taken.display { merged.display = value }
        if let value = taken.keyboard { merged.keyboard = value }
        last = merged
    }
}
