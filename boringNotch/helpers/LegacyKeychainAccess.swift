import Foundation
import Security

/// The login keychain uses process-level interaction controls, rather than
/// LAContext. Serialize these scoped changes and restore the prior policy.
enum LegacyKeychainAccess {
    enum PolicyError: Error { case unavailable }
    private static let lock = NSRecursiveLock()

    static func withInteraction<T>(_ allowed: Bool, operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        var previous: DarwinBoolean = true
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(allowed) == errSecSuccess else { throw PolicyError.unavailable }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try operation()
    }

    private static func currentApplication() -> SecTrustedApplication? {
        let url = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : Bundle.main.executableURL
        guard let url else { return nil }
        var application: SecTrustedApplication?
        let status = url.path.withCString { SecTrustedApplicationCreateFromPath($0, &application) }
        return status == errSecSuccess ? application : nil
    }

    static func accessForCurrentApplication() -> SecAccess? {
        guard let application = currentApplication() else { return nil }
        var access: SecAccess?
        guard SecAccessCreate("Boring Notch Octave enhanced lyrics" as CFString, [application] as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }
}
