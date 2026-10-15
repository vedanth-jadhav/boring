import Foundation

enum AccountFailure: LocalizedError {
    case signIn, unavailable, invalidResponse, missingCLI, denied, timedOut, browserUnavailable, slowDown, rateLimited
    case callbackUnavailable(UInt16)
    var errorDescription: String? {
        switch self {
        case .signIn: "Sign in to your account in your browser, then refresh your usage."
        case .unavailable: "Couldn’t refresh usage. Check your connection and try again."
        case .invalidResponse: "The service didn’t report readable limits. Open its usage dashboard for details."
        case .missingCLI: "Install or update the official Antigravity app or CLI, then sign in again."
        case .denied: "Sign-in wasn’t approved. Try signing in again."
        case .timedOut: "Sign-in timed out. Try again and complete the browser sign-in."
        case .browserUnavailable: "Couldn’t open your browser. Check your default browser and try again."
        case .slowDown: "Waiting for browser authorization…"
        case .rateLimited: "The service asked us to wait before refreshing usage. Try again shortly."
        case .callbackUnavailable(let port): "Couldn’t receive the sign-in callback on local port \(port). Close another active sign-in and retry."
        }
    }
}
