import Foundation
import Network

/// Receives one validated OAuth callback on the loopback interface only.
@MainActor final class NativeOAuthCallback {
    private let state: String
    private let path: String
    private var listener: NWListener?
    private var ready: CheckedContinuation<Void, Error>?
    private var completion: CheckedContinuation<String, Error>?
    private var pending: Result<String, Error>?

    init(state: String, path: String) { self.state = state; self.path = path }

    func start(configuration: NativeOAuthConfiguration) async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: configuration.port)!)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch { throw AccountFailure.callbackUnavailable(configuration.port) }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .ready: self.ready?.resume(); self.ready = nil
                case .failed:
                    self.ready?.resume(throwing: AccountFailure.callbackUnavailable(configuration.port)); self.ready = nil
                    self.finish(.failure(AccountFailure.callbackUnavailable(configuration.port)))
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.receive(connection, buffer: Data()) }
        }
        try await withCheckedThrowingContinuation { ready = $0; listener.start(queue: .main) }
        guard let port = listener.port else { throw AccountFailure.callbackUnavailable(configuration.port) }
        return URL(string: "http://\(configuration.callbackHost):\(port.rawValue)\(path)")!
    }

    func wait() async throws -> String {
        if let pending { return try pending.get() }
        return try await withCheckedThrowingContinuation { completion = $0 }
    }

    func cancel(error: Error = CancellationError()) {
        ready?.resume(throwing: error); ready = nil
        finish(.failure(error))
        listener?.cancel(); listener = nil
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        if buffer.isEmpty { connection.start(queue: .main) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var bytes = buffer
                if let data { bytes.append(data) }
                guard bytes.count <= 8192, error == nil else { connection.cancel(); return }
                guard bytes.range(of: Data("\r\n\r\n".utf8)) != nil else {
                    if complete { connection.cancel() } else { self.receive(connection, buffer: bytes) }
                    return
                }
                let request = String(data: bytes, encoding: .utf8) ?? ""
                let result = Self.authorizationCode(request: request, path: self.path, state: self.state)
                let accepted = result != nil
                let message = accepted ? "You can close this tab and return to Boring Notch." : "This sign-in callback was not accepted. Return to the sign-in tab."
                let body = "<!doctype html><html><meta charset='utf-8'><title>Boring Notch</title><body><h2>\(accepted ? "Sign-in received" : "Sign-in not accepted")</h2><p>\(message)</p></body></html>"
                let response = "HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                if let result { self.finish(result) }
            }
        }
    }

    static func authorizationCode(request: String, path: String, state: String) -> Result<String, Error>? {
        let line = request.components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/1."),
              let url = URLComponents(string: "http://127.0.0.1" + String(parts[1])), url.path == path else { return nil }
        let items = url.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1, items.first(where: { $0.name == "state" })?.value == state else { return nil }
        if items.contains(where: { $0.name == "error" }) { return .failure(AccountFailure.denied) }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return nil }
        return .success(code)
    }

    private func finish(_ result: Result<String, Error>) {
        guard pending == nil else { return }
        pending = result
        completion?.resume(with: result); completion = nil
    }
}
