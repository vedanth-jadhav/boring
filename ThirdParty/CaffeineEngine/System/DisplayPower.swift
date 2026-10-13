import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt
import ObjectiveC.runtime

/// Failure in the display or keyboard backlight layer. `what` is the whole
/// story: which framework, symbol, class or call was missing or refused.
struct DisplayPowerError: Error, LocalizedError, Sendable {
    let what: String

    var errorDescription: String? { what }
}

/// Built-in display brightness and power (spec section 4). With `pmset -a
/// disablesleep 1` macOS never turns the panel off on lid close (that only
/// happens on the system-sleep path), so lid close saves the brightness and
/// sets it to 0, and lid open puts it back.
protocol DisplayDimming: Sendable {
    /// User brightness of the built-in display, 0...1.
    func readBrightness() throws -> Float
    func setBrightness(_ value: Float) throws
    /// Ask the display to sleep now. macOS ignores it while any process holds a display assertion.
    func requestSleep() throws
    /// Declare local user activity so a sleeping display wakes. Best effort, never throws.
    func wake()
    /// Whether the built-in display is asleep (`CGDisplayIsAsleep`). While it
    /// is, `readBrightness()` returns the idle-dim value, not the user's.
    /// No display: false.
    func isAsleep() -> Bool
    /// Why this Mac's display is left alone (a macOS the private calls were
    /// not measured on, a framework that could not be loaded), or nil when
    /// the calls run. Shown in Settings next to the darken toggle.
    func refusal() -> String?
}

extension DisplayDimming {
    func refusal() -> String? { nil }
}

/// Built-in keyboard backlight. Setting the display to 0 does not switch it
/// off; it has to be set on its own.
protocol KeyboardBacklighting: Sendable {
    /// nil when there is no built-in keyboard backlight.
    func readBrightness() throws -> Float?
    func setBrightness(_ value: Float) throws
    /// Whether macOS is holding the backlight down itself: suppressed by
    /// display sleep (reads as 0) or idle-dimmed. A value read then is not
    /// the user's. No keyboard: false.
    func isSuppressedOrDimmed() -> Bool
    /// Why this Mac's keyboard backlight is left alone (a private class
    /// whose methods no longer look as measured, a framework that could not
    /// be loaded), or nil when the calls run.
    func refusal() -> String?
}

extension KeyboardBacklighting {
    func refusal() -> String? { nil }
}

/// Pure helpers shared by the live implementations, tested without the
/// private frameworks.
enum DisplayPower {
    static func clamped(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    /// The built-in panel among the online displays. With an external
    /// monitor in clamshell mode the main display is not the panel.
    static func builtInDisplay(
        among ids: [CGDirectDisplayID],
        isBuiltIn: (CGDirectDisplayID) -> Bool,
        fallback: CGDirectDisplayID
    ) -> CGDirectDisplayID {
        ids.first(where: isBuiltIn) ?? fallback
    }

    static func builtInKeyboards(among ids: [UInt64], isBuiltIn: (UInt64) -> Bool) -> [UInt64] {
        ids.filter(isBuiltIn)
    }

    // MARK: Guards on the private calls

    /// macOS major versions on which the DisplayServices brightness calls
    /// were measured (docs/release-validation.md). A C symbol carries no
    /// type information, so on any other major the calls are refused until
    /// someone measures them again, rather than passing a display id and a
    /// float pointer into a function whose signature may have changed.
    static let measuredDisplayServicesMajors: Set<Int> = [26]

    /// nil when `major` was measured; otherwise why DisplayServices is refused.
    static func displayServicesRefusal(osMajorVersion major: Int) -> String? {
        guard !measuredDisplayServicesMajors.contains(major) else { return nil }
        let measured = measuredDisplayServicesMajors.sorted().map(String.init).joined(separator: ", ")
        return "DisplayServices brightness calls were measured on macOS \(measured) only; this is macOS \(major), so the display is left alone until they are measured again"
    }

    /// Instance method type encodings of the private KeyboardBrightnessClient
    /// measured on macOS 26.2 (25C56, arm64), with the stack offsets
    /// removed: the offsets depend on layout, the types do not. An Objective-C
    /// method carries its encoding at run time, so a changed argument or
    /// return type is seen before the method is called.
    static let measuredKeyboardClientEncodings: [String: String] = [
        "copyKeyboardBacklightIDs": "@@:",
        "isKeyboardBuiltIn:": "B@:Q",
        "brightnessForKeyboard:": "f@:Q",
        "setBrightness:forKeyboard:": "B@:fQ",
        "isBacklightSuppressedOnKeyboard:": "B@:Q",
        "isBacklightDimmedOnKeyboard:": "B@:Q",
    ]

    /// Selectors the backlight cannot work without. The two suppressed and
    /// dimmed queries are optional: a missing one reads as false.
    static let requiredKeyboardClientSelectors = [
        "copyKeyboardBacklightIDs", "isKeyboardBuiltIn:", "brightnessForKeyboard:", "setBrightness:forKeyboard:",
    ]

    /// "B24@0:8Q16" -> "B@:Q".
    static func typeEncodingWithoutOffsets(_ encoding: String) -> String {
        encoding.filter { !$0.isNumber }
    }

    /// nil when every required selector exists and every selector that
    /// exists has the measured encoding; otherwise why the client is refused.
    /// `encodingFor` returns a selector's raw type encoding, nil when the
    /// class has no such method.
    static func keyboardClientRefusal(encodingFor: (String) -> String?) -> String? {
        for name in measuredKeyboardClientEncodings.keys.sorted() {
            guard let raw = encodingFor(name) else {
                if requiredKeyboardClientSelectors.contains(name) {
                    return "KeyboardBrightnessClient has no \(name); the keyboard backlight is left alone until it is measured again"
                }
                continue
            }
            let found = typeEncodingWithoutOffsets(raw)
            let measured = measuredKeyboardClientEncodings[name]!
            if found != measured {
                return "KeyboardBrightnessClient \(name) has type encoding \(found), measured \(measured) on macOS 26; the keyboard backlight is left alone until it is measured again"
            }
        }
        return nil
    }
}

/// Does nothing; the default for SessionManager, AppServices and LidActions
/// so tests and non-display paths need neither private framework. Reading
/// throws, so nothing is journaled and nothing is set.
struct NoopDisplayDimmer: DisplayDimming {
    func readBrightness() throws -> Float { throw DisplayPowerError(what: "no display control") }
    func setBrightness(_ value: Float) throws {}
    func requestSleep() throws {}
    func wake() {}
    func isAsleep() -> Bool { false }
}

/// Does nothing; reads as "no built-in keyboard backlight".
struct NoopKeyboardBacklight: KeyboardBacklighting {
    func readBrightness() throws -> Float? { nil }
    func setBrightness(_ value: Float) throws {}
    func isSuppressedOrDimmed() -> Bool { false }
}

/// Private DisplayServices.framework, measured on macOS 26 (see
/// docs/release-validation.md): Get/SetBrightness take effect at once
/// whether the display is awake, asleep or held by a display assertion.
/// Symbols are resolved once, lazily, under a lock, and only on a macOS
/// major the calls were measured on; a macOS that drops a symbol or was
/// never measured makes every call throw, so the lid close logs and skips
/// rather than crashing.
final class DisplayServicesDimmer: DisplayDimming, @unchecked Sendable {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool

    private struct Symbols {
        let get: GetBrightness
        let set: SetBrightness
        let canChange: CanChangeBrightness
    }

    private static let frameworkPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private let lock = NSLock()
    private let osMajorVersion: Int
    private var resolved: Result<Symbols, DisplayPowerError>?

    /// `osMajorVersion` is injected for tests; the live value is the
    /// running macOS.
    init(osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
        self.osMajorVersion = osMajorVersion
    }

    func readBrightness() throws -> Float {
        let symbols = try self.symbols()
        let display = try changeableDisplay(symbols)
        var value: Float = 0
        let rc = symbols.get(display, &value)
        guard rc == 0 else { throw DisplayPowerError(what: "DisplayServicesGetBrightness failed (\(rc))") }
        return value
    }

    func setBrightness(_ value: Float) throws {
        let symbols = try self.symbols()
        let display = try changeableDisplay(symbols)
        let rc = symbols.set(display, DisplayPower.clamped(value))
        guard rc == 0 else { throw DisplayPowerError(what: "DisplayServicesSetBrightness failed (\(rc))") }
    }

    /// What `pmset displaysleepnow` does. Honoured only when no process
    /// holds a PreventUserIdleDisplaySleep assertion, and deferred by powerd
    /// for ~30 s after any wake.
    func requestSleep() throws {
        let wrangler = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler")
        guard wrangler != 0 else { throw DisplayPowerError(what: "IODisplayWrangler not found") }
        defer { IOObjectRelease(wrangler) }
        let kr = IORegistryEntrySetCFProperty(wrangler, "IORequestIdle" as CFString, kCFBooleanTrue)
        guard kr == KERN_SUCCESS else { throw DisplayPowerError(what: "IORequestIdle refused (\(kr))") }
    }

    func wake() {
        var id: IOPMAssertionID = 0
        let kr = IOPMAssertionDeclareUserActivity("Caffeine lid open" as CFString, kIOPMUserActiveLocal, &id)
        if kr != kIOReturnSuccess {
            Log.error("display wake failed: IOPMAssertionDeclareUserActivity returned \(kr)")
        }
    }

    /// Public CoreGraphics; needs no private symbol. A missing display
    /// (`kCGNullDirectDisplay`) reads as awake.
    func isAsleep() -> Bool {
        CGDisplayIsAsleep(Self.builtInDisplayID()) != 0
    }

    /// Resolves on first use, so the answer is the one the lid close gets.
    func refusal() -> String? {
        do {
            _ = try symbols()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Private

    private func symbols() throws -> Symbols {
        try lock.withLock {
            if let resolved { return try resolved.get() }
            let result = Self.resolve(osMajorVersion: osMajorVersion)
            resolved = result
            return try result.get()
        }
    }

    private static func resolve(osMajorVersion: Int) -> Result<Symbols, DisplayPowerError> {
        if let why = DisplayPower.displayServicesRefusal(osMajorVersion: osMajorVersion) {
            Log.error("display darkening refused: \(why)")
            return .failure(DisplayPowerError(what: why))
        }
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
            return .failure(DisplayPowerError(what: "DisplayServices.framework could not be loaded"))
        }
        func symbol<T>(_ name: String) throws -> T {
            guard let pointer = dlsym(handle, name) else {
                throw DisplayPowerError(what: "DisplayServices.framework has no \(name)")
            }
            return unsafeBitCast(pointer, to: T.self)
        }
        do {
            return .success(Symbols(
                get: try symbol("DisplayServicesGetBrightness"),
                set: try symbol("DisplayServicesSetBrightness"),
                canChange: try symbol("DisplayServicesCanChangeBrightness")
            ))
        } catch {
            return .failure(error as? DisplayPowerError ?? DisplayPowerError(what: error.localizedDescription))
        }
    }

    private func changeableDisplay(_ symbols: Symbols) throws -> CGDirectDisplayID {
        let display = Self.builtInDisplayID()
        guard symbols.canChange(display) else {
            throw DisplayPowerError(what: "display \(display) cannot change brightness")
        }
        return display
    }

    private static func builtInDisplayID() -> CGDirectDisplayID {
        let main = CGMainDisplayID()
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return main }
        return DisplayPower.builtInDisplay(
            among: Array(ids.prefix(Int(count))),
            isBuiltIn: { CGDisplayIsBuiltin($0) != 0 },
            fallback: main
        )
    }
}

/// Selectors of the private CoreBrightness `KeyboardBrightnessClient`,
/// measured on macOS 26. Before the class is used, each of the first four
/// must exist and every one that exists must carry the measured type
/// encoding (`DisplayPower.measuredKeyboardClientEncodings`), so a renamed
/// method throws instead of raising an unrecognized selector and a changed
/// signature throws instead of being called through this bridge. The two
/// suppressed/dimmed queries are optional: each is checked at call time and
/// a missing one reads as false.
@objc protocol KeyboardBrightnessClientBridge: NSObjectProtocol {
    @objc(copyKeyboardBacklightIDs) func copyKeyboardBacklightIDs() -> NSArray?
    @objc(isKeyboardBuiltIn:) func isKeyboardBuiltIn(_ id: UInt64) -> Bool
    @objc(brightnessForKeyboard:) func brightness(forKeyboard id: UInt64) -> Float
    @objc(setBrightness:forKeyboard:) func setBrightness(_ value: Float, forKeyboard id: UInt64) -> Bool
    /// True while display sleep holds the backlight off; reads then are 0.
    @objc(isBacklightSuppressedOnKeyboard:) func isBacklightSuppressed(onKeyboard id: UInt64) -> Bool
    /// True while the keyboard's own idle dim is in effect.
    @objc(isBacklightDimmedOnKeyboard:) func isBacklightDimmed(onKeyboard id: UInt64) -> Bool
}

/// Private CoreBrightness.framework. A write made while the display is
/// asleep reads back 0 but is remembered and applied on the next wake.
final class CoreBrightnessKeyboardBacklight: KeyboardBacklighting, @unchecked Sendable {
    /// Loads the framework and returns the client class; throws with the
    /// reason when either is missing. Injected for tests.
    typealias ClassLoader = @Sendable () throws -> AnyClass

    private static let frameworkPath = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
    private static let className = "KeyboardBrightnessClient"
    private let lock = NSLock()
    private let loadClass: ClassLoader
    private var resolved: Result<any KeyboardBrightnessClientBridge, DisplayPowerError>?

    init(loadClass: @escaping ClassLoader = CoreBrightnessKeyboardBacklight.loadLiveClass) {
        self.loadClass = loadClass
    }

    static func loadLiveClass() throws -> AnyClass {
        guard dlopen(frameworkPath, RTLD_LAZY) != nil else {
            throw DisplayPowerError(what: "CoreBrightness.framework could not be loaded")
        }
        guard let cls = NSClassFromString(className) else {
            throw DisplayPowerError(what: "CoreBrightness.framework has no \(className)")
        }
        return cls
    }

    func readBrightness() throws -> Float? {
        let client = try self.client()
        guard let first = Self.builtInIDs(client).first else { return nil }
        return client.brightness(forKeyboard: first)
    }

    func setBrightness(_ value: Float) throws {
        let client = try self.client()
        let ids = Self.builtInIDs(client)
        guard !ids.isEmpty else { throw DisplayPowerError(what: "no built-in keyboard backlight") }
        for id in ids where !client.setBrightness(DisplayPower.clamped(value), forKeyboard: id) {
            throw DisplayPowerError(what: "setBrightness:forKeyboard: refused for keyboard \(id)")
        }
    }

    /// Each query is behind its own `responds(to:)`: a macOS that drops one
    /// reads as "not held down", which only costs a less trusted sample.
    func isSuppressedOrDimmed() -> Bool {
        guard let client = try? self.client(), let first = Self.builtInIDs(client).first else { return false }
        let suppressed = client.responds(to: NSSelectorFromString("isBacklightSuppressedOnKeyboard:"))
            && client.isBacklightSuppressed(onKeyboard: first)
        let dimmed = client.responds(to: NSSelectorFromString("isBacklightDimmedOnKeyboard:"))
            && client.isBacklightDimmed(onKeyboard: first)
        return suppressed || dimmed
    }

    /// Resolves on first use, so the answer is the one the lid close gets.
    func refusal() -> String? {
        do {
            _ = try client()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Private

    private static func builtInIDs(_ client: any KeyboardBrightnessClientBridge) -> [UInt64] {
        let ids = (client.copyKeyboardBacklightIDs() as? [NSNumber])?.map(\.uint64Value) ?? []
        return DisplayPower.builtInKeyboards(among: ids, isBuiltIn: client.isKeyboardBuiltIn)
    }

    private func client() throws -> any KeyboardBrightnessClientBridge {
        try lock.withLock {
            if let resolved { return try resolved.get() }
            let result = resolve()
            resolved = result
            return try result.get()
        }
    }

    /// Nothing is instantiated until the class has passed the encoding check.
    private func resolve() -> Result<any KeyboardBrightnessClientBridge, DisplayPowerError> {
        let cls: AnyClass
        do {
            cls = try loadClass()
        } catch {
            return .failure(error as? DisplayPowerError ?? DisplayPowerError(what: error.localizedDescription))
        }
        if let why = DisplayPower.keyboardClientRefusal(encodingFor: { name in
            guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)),
                  let encoding = method_getTypeEncoding(method) else { return nil }
            return String(cString: encoding)
        }) {
            Log.error("keyboard backlight refused: \(why)")
            return .failure(DisplayPowerError(what: why))
        }
        guard let type = cls as? NSObject.Type else {
            return .failure(DisplayPowerError(what: "\(Self.className) is not an NSObject subclass"))
        }
        return .success(unsafeBitCast(type.init(), to: (any KeyboardBrightnessClientBridge).self))
    }
}
