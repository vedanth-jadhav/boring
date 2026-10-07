import Foundation
import LocalAuthentication
import Security

enum SpicyLyricsCredential {
    enum StorageError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "Couldn't update the API key in Keychain. Unlock your login keychain and try again."
        }
    }

    private static var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.vedanth.boringnotch.octave.spicy-lyrics",
         kSecAttrAccount as String: "api-key"]
    }

    static func accepts(_ value: String) -> Bool {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (key.hasPrefix("sl_sk_") || key.hasPrefix("sl_pk_")) && key.count >= 20 && key.count <= 512
            && key.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    static func load() -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func save(_ value: String) throws {
        let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        var status = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StorageError.unavailable }
    }

    static func remove() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError.unavailable }
    }
}
