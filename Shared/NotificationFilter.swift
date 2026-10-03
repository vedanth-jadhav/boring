import Foundation

struct NotificationFilter: Sendable {
    var allApps: Bool
    var allowed: Set<String>
    var ignored: Set<String>
    func allows(appName: String?, bundleID: String?) -> Bool {
        let name = NotificationParser.clean(appName)?.lowercased() ?? ""
        guard !["boring notch", "boringnotch", "boring notch octave"].contains(name) else { return false }
        if let bundleID {
            guard !ignored.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }), !bundleID.lowercased().contains("boringnotch") else { return false }
            return allApps || allowed.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame })
        }
        // Unresolved sources are safe to show only in all-apps mode.
        return allApps
    }
}
