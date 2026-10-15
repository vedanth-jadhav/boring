import Foundation

actor CodexUsageClient {
    enum Failure: Error, LocalizedError {
        case pricingChanged
        var errorDescription: String? { "Live pricing is unavailable. Open OpenAI pricing for the current rates." }
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
