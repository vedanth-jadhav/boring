import AppKit
import Foundation

@MainActor enum NativeOAuthSignIn {
    static func signIn(_ provider: AIUsageProvider, instructions: @escaping (String) -> Void) async throws -> AIAccountToken {
        let configuration = try await Task.detached {
            try NativeOAuthConfiguration.configuration(for: provider)
        }.value
        try Task.checkCancellation()
        if provider == .grok {
            let device = try await NativeAccountClient.shared.deviceCode(configuration: configuration)
            instructions("Enter \(device.userCode) in your browser")
            guard NSWorkspace.shared.open(device.verificationURL) else { throw AccountFailure.browserUnavailable }
            var interval = device.interval
            while Date() < device.expiresAt {
                try await Task.sleep(for: .seconds(interval))
                do {
                    if let token = try await NativeAccountClient.shared.pollDevice(code: device, configuration: configuration) { return token }
                } catch AccountFailure.slowDown { interval = min(60, interval + 5) }
            }
            throw AccountFailure.timedOut
        }
        let verifier = try NativeOAuthConfiguration.randomValue()
        let state = try provider == .claude ? verifier : NativeOAuthConfiguration.randomValue()
        let callback = NativeOAuthCallback(state: state, path: configuration.callbackPath)
        defer { callback.cancel() }
        let timeout = Task {
            try await Task.sleep(for: .seconds(300))
            callback.cancel(error: AccountFailure.timedOut)
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            let redirect = try await callback.start(configuration: configuration)
            let authorization = configuration.authorization(redirect: redirect, state: state, verifier: verifier, provider: provider)
            instructions("Waiting for sign-in in your browser…")
            guard NSWorkspace.shared.open(authorization) else { throw AccountFailure.browserUnavailable }
            let code = try await callback.wait()
            try Task.checkCancellation()
            instructions("Connecting your account…")
            return try await NativeAccountClient.shared.exchange(code: code, state: state, verifier: verifier,
                                                               redirect: redirect, configuration: configuration)
        } onCancel: { Task { @MainActor in callback.cancel() } }
    }
}
