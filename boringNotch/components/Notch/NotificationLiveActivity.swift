import SwiftUI

struct NotificationLiveActivity: View {
    @EnvironmentObject private var vm: BoringViewModel
    let notification: SystemNotification
    var body: some View {
        HStack {
            NotificationIconView(bundleID: notification.bundleID)
            Rectangle().fill(.black).frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top)
            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
        }.frame(height: vm.effectiveClosedNotchHeight)
    }
}
