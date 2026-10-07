import Foundation
import CryptoKit

actor CodexUsageClient {
    enum Failure: Error, LocalizedError {
        case notSignedIn, apiKey, expired, unavailable, invalidResponse, pricingChanged
        var errorDescription: String? {
            switch self {
            case .notSignedIn: "Sign in with Codex CLI to see your plan limits. If you use a custom Codex folder, select it below."
            case .apiKey: "API key account. Plan limits apply to ChatGPT sign-in; API usage and billing are available in the OpenAI dashboard."
            case .expired: "Codex sign-in expired. Open Codex CLI to renew your session, then refresh here."
            case .unavailable: "Couldn’t reach Codex. Check your connection and refresh."
            case .invalidResponse: "Codex returned an unfamiliar usage response. Refresh or open the usage dashboard."
            case .pricingChanged: "Live pricing is unavailable. Open OpenAI pricing for the current rates."
            }
        }
    }

    struct Credentials: Sendable {
        let identity: String
        let accessToken: String
        let accountID: String?
    }

    private let session: URLSession
    private let redirectGuard = CodexRedirectGuard()

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 18
        session = URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)
    }

    func credentials(home: URL) async throws -> Credentials {
        var auth: [String: Any]?
        for attempt in 0..<3 {
            if let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { auth = json; break }
            if attempt < 2 { try await Task.sleep(for: .milliseconds(50)) }
        }
        guard let auth else { throw Failure.notSignedIn }
        if auth["auth_mode"] as? String == "apikey" || auth["auth_mode"] as? String == "api_key" {
            throw Failure.apiKey
        }
        guard let tokens = auth["tokens"] as? [String: Any], let token = tokens["access_token"] as? String, !token.isEmpty else {
            if let key = auth["OPENAI_API_KEY"] as? String, !key.isEmpty { throw Failure.apiKey }
            throw Failure.notSignedIn
        }
        let account = tokens["account_id"] as? String
        let identity = SHA256.hash(data: Data("\(account ?? "")|\(tokens["id_token"] as? String ?? token)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return Credentials(identity: identity, accessToken: token, accountID: account)
    }

    func quota(credentials: Credentials, includeResetCredits: Bool = true) async throws -> CodexQuotaSnapshot {
        let json = try await request(path: "usage", credentials: credentials)
        guard var snapshot = CodexQuotaSnapshot.parse(json, at: Date()) else { throw Failure.invalidResponse }
        if includeResetCredits, let reset = try? await request(path: "rate-limit-reset-credits", credentials: credentials) {
            snapshot.applyResetCredits(reset, now: Date())
        }
        try Task.checkCancellation()
        return snapshot
    }

    private func request(path: String, credentials: Credentials) async throws -> [String: Any] {
        let url = URL(string: "https://chatgpt.com/backend-api/wham/\(path)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let account = credentials.accountID, !account.isEmpty {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            try Task.checkCancellation()
            throw Failure.unavailable
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw Failure.expired }
        guard http.statusCode == 200 else { throw Failure.unavailable }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidResponse }
        return json
    }

    func pricing(force: Bool = false) async throws -> CodexRateCatalog {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.vedanth.boringnotch.octave/Codex", isDirectory: true)
        let url = directory.appendingPathComponent("pricing.json")
        let saved = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(CodexRateCatalog.self, from: $0) }
        if !force, let saved, Date().timeIntervalSince(saved.updatedAt) < 86_400 { return saved }
        do {
            let (data, response) = try await session.data(from: CodexRateCatalog.sourceURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else { throw Failure.pricingChanged }
            let catalog = try CodexRateCatalog.parse(html: html)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            if let data = try? JSONEncoder().encode(catalog) { try? data.write(to: url, options: [.atomic]) }
            return catalog
        } catch {
            try Task.checkCancellation()
            if let saved { return saved }
            throw Failure.pricingChanged
        }
    }
}

private final class CodexRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Credentials are only ever sent to the exact OpenAI usage host.
        guard request.url?.scheme == "https", request.url?.host == task.originalRequest?.url?.host else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}
