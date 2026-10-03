import Foundation

/// Pair the two capture transports one-to-one. Repeated identical messages from
/// the same source remain separate occurrences, including during rapid bursts.
struct NotificationCaptureDeduplicator {
    private struct Entry {
        var ids: Set<String>
        var sources: Set<String>
        let canonicalID: String
        var fingerprint: String
        let capturedAt: Date
    }
    private var entries: [Entry] = []
    mutating func ingest(_ item: MirroredNotification, now: Date = Date()) -> MirroredNotification? {
        let source = item.id.hasPrefix("banner:") ? "banner" : "store"
        func normalize(_ value: String?) -> String? { value?.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let fingerprint = NotificationParser.fingerprint(fields: [item.bundleID?.lowercased(), normalize(item.title), normalize(item.body)])
        if let index = entries.firstIndex(where: { $0.ids.contains(item.id) }) {
            guard entries[index].fingerprint != fingerprint else { return nil }
            entries[index].fingerprint = fingerprint
            return renamed(item, id: entries[index].canonicalID)
        }
        if let index = entries.firstIndex(where: {
            !$0.sources.contains(source) && $0.fingerprint == fingerprint && now.timeIntervalSince($0.capturedAt) < 5
        }) {
            entries[index].ids.insert(item.id); entries[index].sources.insert(source)
            return nil
        }
        entries.append(.init(ids: [item.id], sources: [source], canonicalID: item.id, fingerprint: fingerprint, capturedAt: now))
        if entries.count > 128 { entries.removeFirst(entries.count - 128) }
        return item
    }
    private func renamed(_ item: MirroredNotification, id: String) -> MirroredNotification {
        .init(id: id, appName: item.appName, bundleID: item.bundleID, title: item.title, subtitle: item.subtitle,
              body: item.body, receivedAt: item.receivedAt, iconData: item.iconData)
    }
}
