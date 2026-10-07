import Foundation
import Security

@main struct Checks {
    static func main() throws {
        let service = CommandLine.arguments[2]
        let fixture = "sl_sk_keychain_fixture_01234567890123456789"
        switch CommandLine.arguments[1] {
        case "save":
            try SpicyLyricsCredential.save(fixture, service: service)
            print("PASS: scoped signed-app storage")
        case "read":
            var before: DarwinBoolean = true
            var after: DarwinBoolean = true
            SecKeychainGetUserInteractionAllowed(&before)
            guard SpicyLyricsCredential.load(service: service) == fixture else { fatalError("Signed relaunch lost keychain access") }
            SecKeychainGetUserInteractionAllowed(&after)
            guard before.boolValue == after.boolValue else { fatalError("Interaction policy was not restored") }
            print("PASS: signed relaunch reads without UI and restores interaction policy")
        case "reject":
            guard SpicyLyricsCredential.load(service: service) == nil else { fatalError("Untrusted app acquired access") }
            print("PASS: different app identity denied without a prompt")
        case "remove":
            try SpicyLyricsCredential.remove(service: service)
            print("PASS: fixture removed")
        default: fatalError("Unknown check")
        }
    }
}
