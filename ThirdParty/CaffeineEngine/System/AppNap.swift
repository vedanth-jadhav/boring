import CoreFoundation
import Foundation

/// Spec section 5: `NSAppSleepDisabled = YES` for every agent app so App Nap
/// never throttles it, written to each app's own preferences domain exactly
/// like `defaults write <bundle> NSAppSleepDisabled -bool YES`.
///
/// Opt-in (`Config.disableAppNapForAgents`, off by default): with it off
/// Caffeine never writes another app's preferences. With it on, the value
/// the key had before (absent, true or false) is journaled in state.json
/// (`RuntimeState.appNapOverrides`) before the write, and put back at
/// session end, at reconcile, or by backstop.sh with `defaults write` /
/// `defaults delete`, so nothing is left behind after a crash, a force-quit
/// or an uninstall. `SessionManager` owns that ordering; this file is only
/// the preference access, injected so tests never touch real preferences.
protocol AppNapPreferencing: Sendable {
    /// `NSAppSleepDisabled` in the app's current-user, any-host domain, the
    /// one `defaults write <bundle>` and `writeSleepDisabled` use. nil when
    /// the key is absent. Throws when the value is not a boolean, so a
    /// value that cannot be put back exactly is never overwritten.
    func readSleepDisabled(bundleId: String) throws -> Bool?
    /// Sets the key to `value`, or removes it when nil, and persists it.
    func writeSleepDisabled(_ value: Bool?, bundleId: String) throws
}

struct AppNapError: Error, LocalizedError, Sendable {
    let bundleId: String
    let detail: String

    var errorDescription: String? { "\(AppNap.key) for \(bundleId) \(detail)" }
}

enum AppNap {
    static let key = "NSAppSleepDisabled"

    /// The key's value as the Bool it will be written back as: nil when the
    /// key is absent, true or false for a CFBoolean, which is what
    /// `defaults write -bool` and a plist `<true/>` store. Anything else
    /// throws: an integer from `defaults write -int 0`, a string "YES". Such
    /// a value would come back as a boolean, not as what it was, so it is
    /// never overwritten and the app is skipped.
    static func sleepDisabled(from value: CFPropertyList?, bundleId: String) throws -> Bool? {
        guard let value else { return nil }
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw AppNapError(bundleId: bundleId, detail: "is not a boolean; left alone")
        }
        return CFEqual(value, kCFBooleanTrue)
    }

    /// Whether `defaults <verb> <bundleId>`, which backstop.sh restores
    /// with, names the same domain CFPreferences writes. Only ids made of
    /// ASCII letters, digits, `.`, `-` and `_` that start with a letter or
    /// digit qualify. A leading `-` is an option to `defaults` (backstop.sh
    /// refuses the entry and keeps it forever), a `/` or `~` makes it a plist
    /// path, and `defaults` reads NSGlobalDomain as every app's domain where
    /// CFPreferences reads it as an app called that. Any other id is never
    /// journaled or written.
    static func isRestorable(bundleId: String) -> Bool {
        func isAlphanumeric(_ s: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
        }
        let scalars = bundleId.unicodeScalars
        guard bundleId != "NSGlobalDomain", let first = scalars.first, isAlphanumeric(first) else { return false }
        return scalars.allSatisfy { isAlphanumeric($0) || $0 == "." || $0 == "-" || $0 == "_" }
    }
}

/// CFPreferences on the app's own domain.
struct CFAppNapPreferences: AppNapPreferencing {
    func readSleepDisabled(bundleId: String) throws -> Bool? {
        try AppNap.sleepDisabled(
            from: CFPreferencesCopyValue(AppNap.key as CFString, bundleId as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
            bundleId: bundleId)
    }

    func writeSleepDisabled(_ value: Bool?, bundleId: String) throws {
        let app = bundleId as CFString
        let cfValue: CFBoolean? = value.map { $0 ? kCFBooleanTrue : kCFBooleanFalse }
        CFPreferencesSetValue(AppNap.key as CFString, cfValue, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw AppNapError(bundleId: bundleId, detail: "could not be written")
        }
    }
}

/// Reads nothing and writes nothing. The default for every wiring that does
/// not pass the real one, so no test can reach another app's preferences.
struct NoopAppNapPreferences: AppNapPreferencing {
    func readSleepDisabled(bundleId: String) throws -> Bool? { nil }
    func writeSleepDisabled(_ value: Bool?, bundleId: String) throws {}
}
