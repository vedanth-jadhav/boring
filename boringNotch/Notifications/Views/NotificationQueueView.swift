import Defaults
import SwiftUI

/// One recent row at rest. Hover reveals the bounded inbox without changing
/// notification IDs while incoming bursts update the same stack.
struct NotificationQueueView: View {
    @ObservedObject var manager: NotificationManager
    var musicIsPlaying: Bool
    var expanded = false
    @Default(.notificationPreviewPrivacy) private var hidePreview
    private var revealsStack: Bool { expanded }
    private var rows: [MirroredNotification] {
        if revealsStack { return manager.state.notifications }
        return Array(manager.state.notifications.prefix(1))
    }
    private var contentHeight: CGFloat {
        min(280, rows.reduce(0) { $0 + NotificationRowView.height(for: $1, expanded: expanded, hidePreview: hidePreview) + 1 })
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(rows) { item in
                        NotificationRowView(notification: item, manager: manager, hidePreview: hidePreview, expanded: expanded)
                            .transition(.asymmetric(insertion: .offset(y: musicIsPlaying ? -6 : -12).combined(with: .opacity), removal: .opacity))
                        if item.id != rows.last?.id {
                            Rectangle().fill(.white.opacity(0.065)).frame(height: 1).padding(.leading, 47)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(contentHeight < 280)
            .frame(height: contentHeight)
            if manager.state.notifications.count > 1 {
                Text(revealsStack ? "\(manager.state.notifications.count) recent notifications" : "\(manager.state.notifications.count - 1) more · hover to view")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    .frame(height: 18)
            }
        }
        .padding(.horizontal, 6).padding(.bottom, 7)
        .frame(width: 356)
        .accessibilityLabel("Recent notifications")
    }
}
