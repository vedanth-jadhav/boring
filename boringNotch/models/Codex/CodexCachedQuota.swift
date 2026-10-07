import Foundation

struct CodexCachedQuota: Codable {
    let identity: String
    let snapshot: CodexQuotaSnapshot
}
