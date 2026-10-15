import Foundation
import Network

private final class OAuthFixtureState: @unchecked Sendable {
    let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var delayedRefresh = false
    private var badDeviceHost = false
    func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path, default: 0] }
    func response(for request: URLRequest) -> (Int, [String: Any], Double) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        counts[path, default: 0] += 1
        if path == "/oauth2/device/code" {
            return (200, ["device_code": "device-fixture", "user_code": "CODE-1234",
                          "verification_uri": badDeviceHost ? "https://example.com/sign-in" : "https://auth.x.ai/device",
                          "expires_in": 300, "interval": 1], 0)
        }
        if path == "/oauth2/token" {
            if counts[path] == 1 { return (400, ["error": "authorization_pending"], 0) }
            return (200, ["access_token": "device-access-fixture", "refresh_token": "device-refresh-fixture", "expires_in": 3600], 0)
        }
        if path == "/v1/oauth/token" {
            let body = try! JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
            precondition(body["grant_type"] as? String == "refresh_token")
            precondition(body["refresh_token"] as? String == "refresh-fixture")
            return (200, ["access_token": "renewed-fixture", "refresh_token": "rotated-fixture", "expires_in": 3600], delayedRefresh ? 0.25 : 0.05)
        }
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer renewed-fixture")
        precondition(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        return (200, ["five_hour": ["utilization": 20.0]], 0)
    }
    func rejectDeviceHost() { lock.lock(); badDeviceHost = true; lock.unlock() }
    func delayRefresh() { lock.lock(); delayedRefresh = true; lock.unlock() }
}

private final class OAuthFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state = OAuthFixtureState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var request = request
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            request.httpBody = data
        }
        let (status, body, delay) = Self.state.response(for: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        let data = try! JSONSerialization.data(withJSONObject: body)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@main struct NativeOAuthChecks {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
    static func nativeClientFixture() -> Data {
        var data = Data(repeating: 0, count: 0x4000)
        func word(_ offset: Int, _ value: UInt32) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<offset + 4, with: $0) }
        }
        func text(_ offset: Int, _ value: String) { data.replaceSubrange(offset..<offset + value.utf8.count, with: value.utf8) }
        word(0, 0xFEED_FACF); word(4, 0x0100_000C); word(16, 1); word(20, 152)
        word(32, 0x19); word(36, 152); text(40, "__TEXT\0"); word(80, 0x4000); word(96, 1)
        text(104, "__text\0"); word(144, 32); word(152, 0x1000)
        let client = AntigravityOAuthClientDiscovery.consumerClientID
        word(0x1000, 0xB000_0001); word(0x1004, 0x9104_0021)
        word(0x1008, 0xD280_0002 | UInt32(client.utf8.count) << 5); word(0x100C, 0xA900_0801)
        word(0x1010, 0xB000_0001); word(0x1014, 0x9108_0021)
        word(0x1018, 0xD280_0002 | 35 << 5); word(0x101C, 0xA901_0801)
        text(0x2100, client); text(0x2200, "GOCSPX-" + String(repeating: "a", count: 28))
        return data
    }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boring-native-oauth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIAccountTokenStore(directory: directory)
        let now = Date()
        let saved = AIAccountToken(accessToken: "expired-fixture", refreshToken: "refresh-fixture", idToken: nil,
                                   expiresAt: now.addingTimeInterval(-1), clientSecret: nil)
        try store.save(saved, for: .claude)
        let mode = try FileManager.default.attributesOfItem(atPath: store.url(for: .claude).path)[.posixPermissions] as! NSNumber
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as! NSNumber
        expect(mode.intValue == 0o600 && directoryMode.intValue == 0o700, "Tokens must be private to this user")
        expect(!store.contains(.codex), "A token must never connect a different provider")
        let updated = try AIAccountToken.parse(["access_token": "new-fixture", "expires_in": 3600.0], previous: saved)
        expect(updated.refreshToken == saved.refreshToken, "An omitted refresh token must preserve the existing one")
        do { _ = try AIAccountToken.parse(["access_token": "bad-fixture", "expires_in": -1]); fatalError("Invalid expiry accepted") } catch {}
        print("PASS: private token files and token validation")
        let codex = try NativeOAuthConfiguration.configuration(for: .codex)
        let verifier = try NativeOAuthConfiguration.randomValue()
        let state = try NativeOAuthConfiguration.randomValue()
        expect(verifier.count == 43 && state != verifier, "PKCE and state need fresh secure randomness")
        let address = codex.authorization(redirect: URL(string: "http://127.0.0.1:1455/auth/callback")!, state: state,
                                          verifier: verifier, provider: .codex)
        let query = URLComponents(url: address, resolvingAgainstBaseURL: false)!.queryItems!
        expect(query.first(where: { $0.name == "code_challenge_method" })?.value == "S256", "PKCE must use S256")
        expect(!address.absoluteString.contains(verifier), "Never put the PKCE verifier in the browser URL")
        expect(String(data: NativeOAuthConfiguration.form(["code": "a+b&c=d"]), encoding: .utf8) == "code=a%2Bb%26c%3Dd", "Token forms must encode delimiters")
        expect(NativeOAuthCallback.authorizationCode(request: "GET /callback?code=test&state=wrong HTTP/1.1\r\n", path: "/callback", state: state) == nil, "A wrong-state callback must not complete sign-in")
        expect(NativeOAuthCallback.authorizationCode(request: "GET /callback?code=a&code=b&state=\(state) HTTP/1.1\r\n", path: "/callback", state: state) == nil, "Duplicate callback parameters must be rejected")
        let configuration = try NativeOAuthConfiguration.configuration(for: .claude)
        let callback = NativeOAuthCallback(state: state, path: configuration.callbackPath)
        let redirect = try await callback.start(configuration: configuration)
        defer { callback.cancel() }
        expect(redirect.host == "localhost", "Claude's redirect host must match the registered OAuth shape")
        let waiting = Task { try await callback.wait() }
        let network = URLSession(configuration: .ephemeral)
        let (_, wrong) = try await network.data(from: URL(string: redirect.absoluteString + "?code=bad&state=wrong")!)
        expect((wrong as? HTTPURLResponse)?.statusCode == 400, "Reject an invalid real callback without stopping the listener")
        let (_, good) = try await network.data(from: URL(string: redirect.absoluteString + "?code=valid-fixture&state=" + state)!)
        expect((good as? HTTPURLResponse)?.statusCode == 200, "A real loopback callback must succeed")
        let code = try await waiting.value
        expect(code == "valid-fixture", "Only the matching callback may supply the authorization code")
        print("PASS: real loopback callback, state and PKCE")
        let httpConfiguration = URLSessionConfiguration.ephemeral
        httpConfiguration.protocolClasses = [OAuthFixtureProtocol.self]
        let client = NativeAccountClient(tokens: store, session: URLSession(configuration: httpConfiguration))
        async let first = client.quota(.claude)
        async let second = client.quota(.claude)
        let snapshots = try await (first, second)
        expect(snapshots.0.windows.first?.remaining == 80 && snapshots.1.windows.first?.remaining == 80, "Renewed tokens must fetch live usage")
        expect(OAuthFixtureProtocol.state.count("/v1/oauth/token") == 1, "Concurrent reads must share one refresh to protect rotating tokens")
        let rotated = try store.load(.claude)
        expect(rotated.refreshToken == "rotated-fixture", "Persist the rotated refresh token")
        try await client.save(saved, for: .claude)
        OAuthFixtureProtocol.state.delayRefresh()
        let inFlight = Task { try await client.quota(.claude) }
        for _ in 0..<100 {
            if OAuthFixtureProtocol.state.count("/v1/oauth/token") > 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let replacement = AIAccountToken(accessToken: "new-account-fixture", refreshToken: "new-account-refresh", idToken: nil,
                                         expiresAt: now.addingTimeInterval(3600), clientSecret: nil)
        try await client.save(replacement, for: .claude)
        do { _ = try await inFlight.value; fatalError("An old account refresh was accepted") } catch {}
        try await Task.sleep(for: .milliseconds(300))
        let latest = try store.load(.claude)
        expect(latest.accessToken == replacement.accessToken, "Old refreshes must not overwrite a newly signed-in account")
        try await client.disconnect(.claude)
        expect(!store.contains(.claude), "Disconnect must remove only this app's token")
        let authorizationRevision = await client.beginAuthorization(.codex)
        try await client.disconnect(.codex)
        do {
            try await client.save(replacement, for: .codex, authorizationRevision: authorizationRevision)
            fatalError("A disconnected sign-in saved its token")
        } catch is CancellationError {}
        expect(!store.contains(.codex), "Disconnect must invalidate a still-completing browser sign-in")
        let grok = try NativeOAuthConfiguration.configuration(for: .grok)
        let device = try await client.deviceCode(configuration: grok)
        expect(device.verificationURL.host == "auth.x.ai", "Open only the trusted Grok verification host")
        let pending = try await client.pollDevice(code: device, configuration: grok)
        expect(pending == nil, "Pending device authorization must continue waiting")
        let deviceToken = try await client.pollDevice(code: device, configuration: grok)
        expect(deviceToken?.refreshToken == "device-refresh-fixture", "Completed device flow must return refreshable tokens")
        OAuthFixtureProtocol.state.rejectDeviceHost()
        do { _ = try await client.deviceCode(configuration: grok); fatalError("Untrusted device URL accepted") } catch AccountFailure.invalidResponse {}
        let fixture = nativeClientFixture()
        expect(AntigravityOAuthClientDiscovery.secretFromBinary(fixture) == "GOCSPX-" + String(repeating: "a", count: 28), "Match adjacent native-client fields, not arbitrary string-pool ordering")
        expect(AntigravityOAuthClientDiscovery.secretFromBinary(Data(fixture.prefix(100))) == nil, "Truncated artifacts must fail safely")
        if CommandLine.arguments.contains("--live-client") {
            let secret = try AntigravityOAuthClientDiscovery.secret()
            expect(secret.hasPrefix("GOCSPX-"), "Discover the matching consumer OAuth client from installed code")
        }
        print("PASS: native loopback callback, PKCE, CSRF, private token storage, refresh rotation/coalescing, account replacement, disconnect, Antigravity client discovery")
    }
}
