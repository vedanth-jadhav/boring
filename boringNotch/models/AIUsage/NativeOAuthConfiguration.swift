import CryptoKit
import Foundation
import Security

struct NativeOAuthConfiguration: Sendable {
    let clientID: String
    let clientSecret: String?
    let authorizationURL: URL
    let tokenURL: URL
    let scope: String
    let port: UInt16
    let callbackPath: String
    let callbackHost: String
    let sendsJSON: Bool

    static func configuration(for provider: AIUsageProvider, savedSecret: String? = nil) throws -> Self {
        switch provider {
        case .codex:
            return Self(clientID: "app_EMoamEEZ73f0CkXaXp7hrann", clientSecret: nil,
                        authorizationURL: URL(string: "https://auth.openai.com/oauth/authorize")!,
                        tokenURL: URL(string: "https://auth.openai.com/oauth/token")!,
                        scope: "openid profile email offline_access", port: 1455,
                        callbackPath: "/auth/callback", callbackHost: "127.0.0.1", sendsJSON: false)
        case .claude:
            return Self(clientID: "9d1c250a-e61b-44d9-88ed-5944d1962f5e", clientSecret: nil,
                        authorizationURL: URL(string: "https://claude.ai/oauth/authorize")!,
                        tokenURL: URL(string: "https://platform.claude.com/v1/oauth/token")!,
                        scope: "user:profile user:inference", port: 0,
                        callbackPath: "/callback", callbackHost: "localhost", sendsJSON: true)
        case .antigravity:
            let secret = try savedSecret ?? AntigravityOAuthClientDiscovery.secret()
            return Self(clientID: AntigravityOAuthClientDiscovery.consumerClientID, clientSecret: secret,
                        authorizationURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                        tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
                        scope: "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email",
                        port: 0, callbackPath: "/callback", callbackHost: "127.0.0.1", sendsJSON: false)
        case .grok:
            return Self(clientID: "b1a00492-073a-47ea-816f-4c329264a828", clientSecret: nil,
                        authorizationURL: URL(string: "https://auth.x.ai/oauth2/device/code")!,
                        tokenURL: URL(string: "https://auth.x.ai/oauth2/token")!,
                        scope: "openid profile email offline_access grok-cli:access api:access",
                        port: 0, callbackPath: "/callback", callbackHost: "127.0.0.1", sendsJSON: false)
        }
    }

    func authorization(redirect: URL, state: String, verifier: String, provider: AIUsageProvider) -> URL {
        var components = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)!
        var values = ["client_id": clientID, "redirect_uri": redirect.absoluteString, "response_type": "code",
                      "scope": scope, "state": state, "code_challenge_method": "S256",
                      "code_challenge": Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))]
        if provider == .codex {
            values["id_token_add_organizations"] = "true"
            values["codex_cli_simplified_flow"] = "true"
            values["originator"] = "codex_cli_rs"
        } else if provider == .claude { values["code"] = "true" }
        else if provider == .antigravity { values["access_type"] = "offline"; values["prompt"] = "select_account consent" }
        components.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AccountFailure.unavailable }
        return base64URL(Data(bytes))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func form(_ fields: [String: String]) -> Data {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: safe)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: safe)!)"
        }.joined(separator: "&").utf8)
    }
}
