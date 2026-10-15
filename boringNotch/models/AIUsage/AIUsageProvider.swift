import Foundation

enum AIUsageProvider: String, CaseIterable, Identifiable, Sendable {
    case codex, claude, antigravity, grok
    var id: Self { self }
    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .antigravity: "Antigravity"
        case .grok: "Grok"
        }
    }
    var accountTitle: String {
        switch self {
        case .codex: "ChatGPT"
        case .antigravity: "Google"
        default: title
        }
    }
    var dashboard: URL {
        let address = switch self {
        case .codex: "https://chatgpt.com/codex/settings/usage"
        case .claude: "https://claude.ai/settings/usage"
        case .antigravity: "https://antigravity.google/"
        case .grok: "https://grok.com/?_s=usage"
        }
        return URL(string: address)!
    }
}
