import Foundation
import LocalAuthentication
import Security

enum SpicyLyricsCredential {
    enum SavedStatus: Sendable { case available, missing, needsAccess }
    enum StorageError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "Couldn't update the API key in Keychain. Unlock your login keychain and try again."
        }
    }

    private static func identity(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "api-key"]
    }

    static let service = "local.vedanth.boringnotch.octave.spicy-lyrics"

    static func accepts(_ value: String) -> Bool {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (key.hasPrefix("sl_sk_") || key.hasPrefix("sl_pk_")) && key.count >= 20 && key.count <= 512
            && key.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    static func load(service: String = service) -> String? {
        try? LegacyKeychainAccess.withInteraction(false) {
            let identity = identity(service: service)
            return read(identity: identity)
        }
    }

    static func savedStatus() -> SavedStatus {
        if load() != nil { return .available }
        return (try? LegacyKeychainAccess.withInteraction(false) {
            var query = identity(service: service)
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            return status == errSecItemNotFound ? .missing : .needsAccess
        }) ?? .needsAccess
    }

    /// Authentication is permitted only after the user presses the explicit
    /// settings action. No credential value is exposed outside this helper.
    static func authorizeSavedKey() throws {
        try LegacyKeychainAccess.withInteraction(true) {
            let identity = identity(service: service)
            guard read(identity: identity, allowInteraction: true) != nil else {
                throw StorageError.unavailable
            }
        }
    }

    private static func read(identity: [String: Any], allowInteraction: Bool = false) -> String? {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func save(_ value: String, service: String = service) throws {
        try LegacyKeychainAccess.withInteraction(true) {
            let identity = identity(service: service)
            let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
            var status = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = identity
                item[kSecValueData as String] = data
                guard let access = LegacyKeychainAccess.accessForCurrentApplication() else { throw StorageError.unavailable }
                item[kSecAttrAccess as String] = access
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw StorageError.unavailable }
        }
    }

    static func remove(service: String = service) throws {
        try LegacyKeychainAccess.withInteraction(true) {
            let identity = identity(service: service)
            let status = SecItemDelete(identity as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError.unavailable }
        }
    }
}
