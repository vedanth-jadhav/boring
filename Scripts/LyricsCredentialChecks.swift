import Foundation
import Security

@main struct Checks {
    static func main() throws {
        #if KEYCHAIN_REBUILT_FIXTURE
        print("PASS: rebuilt executable uses the stable signed identity")
        #endif
        let service = CommandLine.arguments[2]
        let fixture = "sl_sk_keychain_fixture_01234567890123456789"
        switch CommandLine.arguments[1] {
        case "save":
            try SpicyLyricsCredential.save(fixture, service: service)
            print("PASS: scoped signed-app storage")
        case "trust-rebuild":
            let identity: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                           kSecAttrService as String: service, kSecAttrAccount as String: "api-key"]
            try LegacyKeychainAccess.withInteraction(false) {
                try LegacyKeychainAccess.authorizeCurrentApplication(identity: identity,
                    applicationURL: URL(fileURLWithPath: CommandLine.arguments[3]))
            }
            print("PASS: existing credential retained while rebuild access is authorized")
        case "read":
            var before: DarwinBoolean = true
            var after: DarwinBoolean = true
            SecKeychainGetUserInteractionAllowed(&before)
            guard SpicyLyricsCredential.loadResult(service: service) == .loaded(fixture) else { fatalError("Signed relaunch lost keychain access") }
            SecKeychainGetUserInteractionAllowed(&after)
            guard before.boolValue == after.boolValue else { fatalError("Interaction policy was not restored") }
            print("PASS: signed relaunch reads without UI and restores interaction policy")
        case "reject":
            guard case .inaccessible(let status) = SpicyLyricsCredential.loadResult(service: service),
                  SpicyLyricsCredential.requiresAuthorization(status) else { fatalError("Expected an explicit authorization failure") }
            print("PASS: different app identity denied without a prompt")
        case "remove":
            try SpicyLyricsCredential.remove(service: service)
            print("PASS: fixture removed")
        default: fatalError("Unknown check")
        }
    }
}
