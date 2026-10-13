import SwiftUI
import CaffeineEngine

struct CaffeineAppSummary: View {
    @ObservedObject private var settings = CaffeineSettings.shared
    @ObservedObject private var manager = FocusSessionManager.shared
    @ObservedObject private var engine = FocusSessionManager.shared.caffeine
    let editing: Bool
    let action: () -> Void

    private var keptApps: [CaffeineAppChoice] {
        settings.apps.filter { app in
            manager.session.state == .running ? (app.alwaysOn || engine.keptAppIDs.contains(app.id)) : settings.isKept(app)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                HStack(spacing: -5) {
                    ForEach(Array(keptApps.filter(\.running).prefix(4))) { app in
                        Image(nsImage: app.icon).resizable().frame(width: 22, height: 22)
                            .padding(2).background(.black, in: RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
                    }
                }
                Text("\(keptApps.count) apps stay on").font(.system(size: 11, weight: .medium))
                Text("·").foregroundStyle(.white.opacity(0.45))
                Text(editing ? "Edit apps" : "View choices").font(.system(size: 11)).foregroundStyle(.orange)
                Spacer(minLength: 0)
                Image(systemName: "slider.horizontal.3").font(.system(size: 12)).foregroundStyle(.orange)
            }
            .padding(.horizontal, 12).frame(height: 37)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .help("Choose the apps and settings for Caffeine")
        .onAppear(perform: settings.refresh)
    }
}
