import Foundation
import Security

private let stableService = SpicyLyricsCredential.service + ".stable"

final class CredentialService: NSObject, LyricsKeychainProtocol {
    private let queue = DispatchQueue(label: "BoringNotch.LyricsKeychain")

    func perform(_ operation: String, value: String?, reply: @escaping (String?, Int32) -> Void) {
        queue.async {
            do {
                switch operation {
                case "load":
                    var result = SpicyLyricsCredential.loadResult(service: stableService)
                    if result == .missing {
                        result = SpicyLyricsCredential.loadResult()
                        if case .loaded(let key) = result {
                            // Already-authorized reads can migrate without presenting any UI.
                            try LegacyKeychainAccess.withInteraction(false) {
                                try SpicyLyricsCredential.save(key, service: stableService)
                            }
                        }
                    }
                    switch result {
                    case .loaded(let key): reply(key, errSecSuccess)
                    case .missing: reply(nil, errSecItemNotFound)
                    case .inaccessible(let status): reply(nil, status)
                    }
                case "authorize":
                    let key: String
                    if SpicyLyricsCredential.loadResult(service: stableService) == .missing {
                        // Copy the existing secret once; retain the original item and its access policy.
                        key = try SpicyLyricsCredential.authorizeSavedKey()
                        try SpicyLyricsCredential.save(key, service: stableService)
                    } else {
                        key = try SpicyLyricsCredential.authorizeSavedKey(service: stableService)
                    }
                    reply(key, errSecSuccess)
                case "save":
                    guard let value, SpicyLyricsCredential.accepts(value) else { reply(nil, errSecParam); return }
                    try SpicyLyricsCredential.save(value, service: stableService)
                    reply(nil, errSecSuccess)
                case "remove":
                    try SpicyLyricsCredential.remove(service: stableService)
                    try SpicyLyricsCredential.remove()
                    reply(nil, errSecSuccess)
                default: reply(nil, errSecParam)
                }
            } catch { reply(nil, errSecAuthFailed) }
        }
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // XPC checks each message against the app identifier and our signing certificate.
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return false }
        let ownRequirement = text as String
        guard ownRequirement.contains("certificate") else { return false }
        connection.setCodeSigningRequirement(ownRequirement.replacingOccurrences(
            of: "identifier \"local.vedanth.boringnotch.octave.LyricsKeychain\"",
            with: "identifier \"local.vedanth.boringnotch.octave\""))
        connection.exportedInterface = NSXPCInterface(with: LyricsKeychainProtocol.self)
        connection.exportedObject = CredentialService()
        connection.resume()
        return true
    }
}

#if KEYCHAIN_FIXTURE
// Exercise the migration without requiring a password or touching the user's key.
if CommandLine.arguments.count > 1 {
    let fixture = "sl_sk_keychain_fixture_01234567890123456789"
    switch CommandLine.arguments[1] {
    case "seed-legacy": try SpicyLyricsCredential.save(fixture)
    case "verify-migration":
        guard SpicyLyricsCredential.load() == fixture,
              SpicyLyricsCredential.load(service: stableService) == fixture else { fatalError("Migration lost a credential") }
        print("PASS: migration creates a stable copy and retains the original credential")
    case "remove-fixtures":
        try LegacyKeychainAccess.withInteraction(false) {
            try SpicyLyricsCredential.remove(service: stableService)
            try SpicyLyricsCredential.remove()
        }
    default: fatalError("Unknown fixture operation")
    }
    exit(0)
}
#endif

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
