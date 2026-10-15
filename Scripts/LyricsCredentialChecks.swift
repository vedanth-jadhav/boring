import Foundation
import Security

@main struct Checks {
    static func main() throws {
        #if KEYCHAIN_REBUILT_FIXTURE
        print("PASS: rebuilt application uses the unchanged credential helper")
        #endif
        let service = CommandLine.arguments[2]
        let fixture = "sl_sk_keychain_fixture_01234567890123456789"
        switch CommandLine.arguments[1] {
        case "save":
            try SpicyLyricsCredential.save(fixture, service: service)
            print("PASS: scoped signed-app storage")
        case "authorize":
            guard try SpicyLyricsCredential.authorizeSavedKey(service: service) == fixture else { fatalError("Migration changed the key") }
            print("PASS: existing credential migrated without changing its value")
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
        case "reject-xpc":
            guard case .inaccessible = SpicyLyricsCredential.loadResult(service: service) else {
                fatalError("Untrusted caller obtained a credential")
            }
            print("PASS: credential helper rejects a different signed application")
        case "remove":
            try SpicyLyricsCredential.remove(service: service)
            print("PASS: fixture removed")
        default: fatalError("Unknown check")
        }
    }
}
