import Foundation
import LocalAuthentication
import Security

enum SpicyLyricsCredential {
    enum SavedStatus: Sendable { case available, missing, needsAccess, unavailable }
    enum LoadResult: Sendable, Equatable {
        case loaded(String), missing, inaccessible(OSStatus)
    }

    static func requiresAuthorization(_ status: OSStatus) -> Bool {
        status == errSecAuthFailed || status == errSecInteractionNotAllowed || status == errSecUserCanceled
    }
    static func isTemporaryFailure(_ status: OSStatus) -> Bool {
        !requiresAuthorization(status) && status != errSecDecode
    }

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

    #if KEYCHAIN_FIXTURE
    static let service = Bundle.main.object(forInfoDictionaryKey: "BNKeychainFixtureService") as! String
    #else
    static let service = "local.vedanth.boringnotch.octave.spicy-lyrics"
    #endif

    static func accepts(_ value: String) -> Bool {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (key.hasPrefix("sl_sk_") || key.hasPrefix("sl_pk_")) && key.count >= 20 && key.count <= 512
            && key.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    static func load(service: String = service) -> String? {
        guard case .loaded(let key) = loadResult(service: service) else { return nil }
        return key
    }

    static func loadResult(service: String = service) -> LoadResult {
        #if BORING_LOCAL_BUILD
        if service == Self.service { return LyricsKeychainClient.perform("load") }
        #endif
        do {
            return try LegacyKeychainAccess.withInteraction(false) { read(identity: identity(service: service)) }
        } catch {
            return .inaccessible(errSecNotAvailable)
        }
    }

    static func savedStatus() -> SavedStatus {
        switch loadResult() {
        case .loaded: return .available
        case .missing: return .missing
        case .inaccessible(let status):
            return requiresAuthorization(status) ? .needsAccess : .unavailable
        }
    }

    /// Authentication is permitted only after the user presses the explicit
    /// settings action. No credential value is exposed outside this helper.
    static func authorizeSavedKey(service: String = service) throws -> String {
        #if BORING_LOCAL_BUILD
        if service == Self.service {
            guard case .loaded(let key) = LyricsKeychainClient.perform("authorize") else { throw StorageError.unavailable }
            return key
        }
        #endif
        return try LegacyKeychainAccess.withInteraction(true) {
            guard case .loaded(let key) = read(identity: identity(service: service), allowInteraction: true) else {
                throw StorageError.unavailable
            }
            return key
        }
    }

    private static func read(identity: [String: Any], allowInteraction: Bool = false) -> LoadResult {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return status == errSecItemNotFound ? .missing : .inaccessible(status)
        }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .inaccessible(errSecDecode) }
        return .loaded(key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func save(_ value: String, service: String = service) throws {
        #if BORING_LOCAL_BUILD
        if service == Self.service {
            guard case .loaded = LyricsKeychainClient.perform("save", value: value) else { throw StorageError.unavailable }
            return
        }
        #endif
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
        #if BORING_LOCAL_BUILD
        if service == Self.service {
            guard case .loaded = LyricsKeychainClient.perform("remove") else { throw StorageError.unavailable }
            return
        }
        #endif
        try LegacyKeychainAccess.withInteraction(true) {
            let identity = identity(service: service)
            let status = SecItemDelete(identity as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError.unavailable }
        }
    }
}
