import Foundation

struct AIAccountToken: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresAt: Date
    let clientSecret: String?

    static func parse(_ json: [String: Any], previous: Self? = nil, clientSecret: String? = nil, defaultLifetime: Double? = nil, now: Date = Date()) throws -> Self {
        guard let access = json["access_token"] as? String, !access.isEmpty,
              let duration = json["expires_in"] as? Double ?? (json["expires_in"] == nil ? defaultLifetime : nil), duration.isFinite, duration > 0, duration < 366 * 86_400 else {
            throw AccountFailure.invalidResponse
        }
        return Self(accessToken: access, refreshToken: json["refresh_token"] as? String ?? previous?.refreshToken,
                    idToken: json["id_token"] as? String ?? previous?.idToken, expiresAt: now.addingTimeInterval(duration),
                    clientSecret: clientSecret ?? previous?.clientSecret)
    }

    var codexAccountID: String? {
        (Self.claims(idToken ?? accessToken)?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
    }

    static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
