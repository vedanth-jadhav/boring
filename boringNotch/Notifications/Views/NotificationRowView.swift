import SwiftUI

struct NotificationRowView: View {
    let notification: MirroredNotification
    @ObservedObject var manager: NotificationManager
    let hidePreview: Bool
    var expanded = false
    @ViewState private var hovered = false
    static func height(for item: MirroredNotification, expanded: Bool, hidePreview: Bool) -> CGFloat {
        guard expanded else { return 47 }
        let text = hidePreview ? "Preview hidden" : item.body ?? item.subtitle ?? "New notification"
        let bounds = (text as NSString).boundingRect(with: NSSize(width: 240, height: 1000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 10)])
        return max(47, 16 + min(48, ceil(bounds.height))) + 16
    }
    private var timestamp: String {
        let seconds = max(0, Date().timeIntervalSince(notification.receivedAt))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        return "\(Int(seconds / 3600))h"
    }
    var body: some View {
        HStack(spacing: 4) {
            Button {
                Task { await manager.open(notification) }
            } label: {
                HStack(spacing: 8) {
                    NotificationIconView(bundleID: notification.bundleID, nativeIcon: notification.iconData)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hidePreview ? notification.appName ?? "Notification" : notification.title ?? notification.appName ?? "Notification")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.96)).lineLimit(1)
                        Text(hidePreview ? "Preview hidden" : notification.body ?? notification.subtitle ?? "New notification")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.72)).lineLimit(expanded ? 4 : 1)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if !hovered {
                        Text(timestamp).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1).frame(maxWidth: 44, alignment: .trailing)
                    }
                }.frame(maxWidth: .infinity, minHeight: 47).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("Opens \(notification.appName ?? "the native app")")
            if hovered {
                Button { manager.dismissActive(token: notification.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65)).frame(width: 24, height: 24).contentShape(Circle())
                }.buttonStyle(.plain).accessibilityLabel("Dismiss notification").help("Dismiss")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, expanded ? 8 : 0).frame(minHeight: 47)
        .background(hovered ? Color.white.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .onHover { hovered = $0 }
    }
}
