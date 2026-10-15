import Foundation

actor NativeAccountClient {
    static let shared = NativeAccountClient()
    private let tokens: AIAccountTokenStore
    private let session: URLSession
    private var revisions: [AIUsageProvider: Int] = [:]
    private var refreshes: [AIUsageProvider: Task<AIAccountToken, Error>] = [:]

    init(tokens: AIAccountTokenStore = AIAccountTokenStore(), session: URLSession? = nil) {
        self.tokens = tokens
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: configuration, delegate: OAuthRedirectBlocker(), delegateQueue: nil)
        }
    }

    func connected(_ provider: AIUsageProvider) -> Bool { tokens.contains(provider) }

    func beginAuthorization(_ provider: AIUsageProvider) -> Int {
        revisions[provider, default: 0] += 1
        refreshes.removeValue(forKey: provider)?.cancel()
        return revisions[provider, default: 0]
    }

    func save(_ token: AIAccountToken, for provider: AIUsageProvider, authorizationRevision: Int? = nil) throws {
        try Task.checkCancellation()
        if let expected = authorizationRevision, expected != revisions[provider, default: 0] { throw CancellationError() }
        revisions[provider, default: 0] += 1
        refreshes.removeValue(forKey: provider)?.cancel()
        try tokens.save(token, for: provider)
    }

    func disconnect(_ provider: AIUsageProvider) throws {
        revisions[provider, default: 0] += 1
        refreshes.removeValue(forKey: provider)?.cancel()
        try tokens.remove(provider)
    }

    func exchange(code: String, state: String, verifier: String, redirect: URL,
                  configuration: NativeOAuthConfiguration) async throws -> AIAccountToken {
        var fields = ["grant_type": "authorization_code", "client_id": configuration.clientID,
                      "code": code, "code_verifier": verifier, "redirect_uri": redirect.absoluteString]
        if configuration.sendsJSON { fields["state"] = state }
        if let secret = configuration.clientSecret { fields["client_secret"] = secret }
        let json = try await tokenRequest(configuration: configuration, fields: fields)
        return try AIAccountToken.parse(json, clientSecret: configuration.clientSecret)
    }

    func deviceCode(configuration: NativeOAuthConfiguration) async throws -> OAuthDeviceCode {
        let json = try await request(url: configuration.authorizationURL,
                                     form: ["client_id": configuration.clientID, "scope": configuration.scope])
        guard let code = json["device_code"] as? String, !code.isEmpty,
              let userCode = json["user_code"] as? String, !userCode.isEmpty,
              let address = json["verification_uri_complete"] as? String ?? json["verification_uri"] as? String,
              let url = URL(string: address), url.scheme == "https", url.host == "auth.x.ai",
              let seconds = json["expires_in"] as? Double, seconds.isFinite, seconds > 0, seconds <= 1800 else {
            throw AccountFailure.invalidResponse
        }
        let interval = json["interval"] as? Double ?? 5
        guard interval.isFinite, (1...60).contains(interval) else { throw AccountFailure.invalidResponse }
        return OAuthDeviceCode(deviceCode: code, userCode: userCode, verificationURL: url,
                               expiresAt: Date().addingTimeInterval(seconds), interval: interval)
    }

    func pollDevice(code: OAuthDeviceCode, configuration: NativeOAuthConfiguration) async throws -> AIAccountToken? {
        let json = try await request(url: configuration.tokenURL, form: ["grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                                "client_id": configuration.clientID, "device_code": code.deviceCode], allowsOAuthError: true)
        if json["error"] as? String == "authorization_pending" { return nil }
        if json["error"] as? String == "slow_down" { throw AccountFailure.slowDown }
        if json["error"] != nil { throw AccountFailure.denied }
        return try AIAccountToken.parse(json, defaultLifetime: 3600)
    }

    func quota(_ provider: AIUsageProvider) async throws -> CodexQuotaSnapshot {
        let version = revisions[provider, default: 0]
        let token = try await accessToken(provider)
        let json: [String: Any]
        var snapshot: CodexQuotaSnapshot?
        switch provider {
        case .codex:
            var headers: [String: String] = [:]
            if let account = token.codexAccountID { headers["ChatGPT-Account-Id"] = account }
            json = try await request(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!, token: token, headers: headers)
            snapshot = CodexQuotaSnapshot.parse(json, at: Date())
            if let resets = try? await request(url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!, token: token, headers: headers) {
                snapshot?.applyResetCredits(resets, now: Date())
            }
        case .claude:
            json = try await request(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, token: token,
                                    headers: ["anthropic-beta": "oauth-2025-04-20"])
            snapshot = AIUsageParser.claude(json, at: Date())
        case .grok:
            json = try await request(url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!, token: token,
                                    headers: ["x-xai-token-auth": "xai-grok-cli"])
            snapshot = AIUsageParser.grokCredits(json, at: Date())
        case .antigravity:
            let base = "https://cloudcode-pa.googleapis.com/v1internal:"
            let headers = ["User-Agent": "antigravity/hub/2.9.1 darwin/arm64"]
            let account = try await request(url: URL(string: base + "loadCodeAssist")!, token: token, headers: headers,
                                           body: ["metadata": ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]])
            if (account["ineligibleTiers"] as? [[String: Any]])?.contains(where: { $0["reasonCode"] as? String == "GOOGLE_TOS_NOT_SUPPORTED_BY_CLIENT" }) == true {
                throw AccountFailure.signIn
            }
            let project = account["cloudaicompanionProject"] as? String
                ?? (account["cloudaicompanionProject"] as? [String: Any])?["id"] as? String
            json = try await request(url: URL(string: base + "retrieveUserQuotaSummary")!, token: token, headers: headers,
                                     body: project.map { ["project": $0] } ?? [:])
            snapshot = AIUsageParser.antigravityRemote(json, at: Date())
            snapshot?.plan = (account["paidTier"] as? [String: Any])?["name"] as? String
                ?? (account["currentTier"] as? [String: Any])?["name"] as? String
        }
        try Task.checkCancellation()
        guard revisions[provider, default: 0] == version else { throw CancellationError() }
        guard let snapshot else { throw AccountFailure.invalidResponse }
        return snapshot
    }

    private func accessToken(_ provider: AIUsageProvider) async throws -> AIAccountToken {
        let saved = try tokens.load(provider)
        guard saved.expiresAt.timeIntervalSinceNow <= 90 else { return saved }
        if let refresh = refreshes[provider] { return try await refresh.value }
        guard let value = saved.refreshToken, !value.isEmpty else { throw AccountFailure.signIn }
        let version = revisions[provider, default: 0]
        let task = Task {
            let configuration = try NativeOAuthConfiguration.configuration(for: provider, savedSecret: saved.clientSecret)
            var fields = ["grant_type": "refresh_token", "client_id": configuration.clientID, "refresh_token": value]
            if let secret = configuration.clientSecret { fields["client_secret"] = secret }
            let json = try await self.tokenRequest(configuration: configuration, fields: fields)
            let updated = try AIAccountToken.parse(json, previous: saved, defaultLifetime: provider == .grok ? 3600 : nil)
            try Task.checkCancellation()
            guard self.revisions[provider, default: 0] == version else { throw CancellationError() }
            try self.tokens.save(updated, for: provider)
            return updated
        }
        refreshes[provider] = task
        defer { if revisions[provider, default: 0] == version { refreshes[provider] = nil } }
        return try await task.value
    }

    private func tokenRequest(configuration: NativeOAuthConfiguration, fields: [String: String]) async throws -> [String: Any] {
        if configuration.sendsJSON { return try await request(url: configuration.tokenURL, body: fields) }
        return try await request(url: configuration.tokenURL, form: fields)
    }

    private func request(url: URL, token: AIAccountToken? = nil, headers: [String: String] = [:],
                         body: [String: Any]? = nil, form: [String: String]? = nil,
                         allowsOAuthError: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let form {
            request.httpMethod = "POST"; request.httpBody = NativeOAuthConfiguration.form(form)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { try Task.checkCancellation(); throw AccountFailure.unavailable }
        guard let http = response as? HTTPURLResponse, data.count <= 1_000_000 else { throw AccountFailure.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw AccountFailure.signIn }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AccountFailure.invalidResponse }
        if allowsOAuthError, http.statusCode == 400, json["error"] is String { return json }
        if json["error"] as? String == "invalid_grant" { throw AccountFailure.signIn }
        if http.statusCode == 429 { throw AccountFailure.rateLimited }
        guard http.statusCode == 200 else { throw AccountFailure.unavailable }
        return json
    }
}

private final class OAuthRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
