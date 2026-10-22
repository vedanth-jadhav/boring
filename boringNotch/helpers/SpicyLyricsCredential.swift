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
        case status(OSStatus)
        case invalidKey
        case verificationFailed
        var errorDescription: String? {
            switch self {
            case .invalidKey: return "Paste a Spicy Lyrics key beginning with sl_sk_ or sl_pk_."
            case .verificationFailed: return "Couldn't verify the Keychain change. Keep your copy of the key and try again."
            case .status(errSecUserCanceled): return "Keychain authorization was canceled. Your saved key was kept."
            case .status(errSecDecode): return "The saved key couldn't be read. Paste a replacement key."
            case .status(let status) where requiresAuthorization(status):
                return "macOS needs permission to access your saved key. Use Authorize saved key and try again."
            case .unavailable, .status:
                return "Couldn't access macOS Keychain. Unlock your login keychain and try again."
            }
        }
    }

    private static func storageError(_ result: LoadResult) -> StorageError {
        if case .inaccessible(let status) = result { return .status(status) }
        return .unavailable
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
            let result = LyricsKeychainClient.perform("authorize")
            guard case .loaded(let key) = result else { throw storageError(result) }
            return key
        }
        #endif
        return try LegacyKeychainAccess.withInteraction(true) {
            let result = read(identity: identity(service: service), allowInteraction: true)
            guard case .loaded(let key) = result else { throw storageError(result) }
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
              accepts(key) else { return .inaccessible(errSecDecode) }
        return .loaded(key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func save(_ value: String, service: String = service) throws {
        guard accepts(value) else { throw StorageError.invalidKey }
        #if BORING_LOCAL_BUILD
        if service == Self.service {
            let result = LyricsKeychainClient.perform("save", value: value)
            guard case .loaded = result else { throw storageError(result) }
            let verified = loadResult()
            if case .inaccessible = verified { throw storageError(verified) }
            guard verified == .loaded(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw StorageError.verificationFailed
            }
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
            guard status == errSecSuccess else { throw StorageError.status(status) }
        }
    }

    static func remove(service: String = service) throws {
        #if BORING_LOCAL_BUILD
        if service == Self.service {
            let result = LyricsKeychainClient.perform("remove")
            guard case .loaded = result else { throw storageError(result) }
            let verified = loadResult()
            if case .inaccessible = verified { throw storageError(verified) }
            guard verified == .missing else { throw StorageError.verificationFailed }
            return
        }
        #endif
        try LegacyKeychainAccess.withInteraction(true) {
            let identity = identity(service: service)
            let status = SecItemDelete(identity as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError.status(status) }
        }
    }
}
