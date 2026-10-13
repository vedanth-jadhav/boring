import SwiftUI
import CaffeineEngine

struct CaffeineOptionsView: View {
    @ObservedObject var settings: CaffeineSettings
    @ObservedObject private var manager = FocusSessionManager.shared
    @ObservedObject private var engine = FocusSessionManager.shared.caffeine
    @ViewState private var enabling = false
    @ViewState private var setupMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(manager.isActive ? "Changes apply to your next session." : "When the lid closes")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
            VStack(spacing: 12) {
                HStack {
                    Label("Low Power Mode", systemImage: "leaf").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Toggle("Low Power Mode", isOn: $settings.lowPower).labelsHidden()
                }.help("Save battery while your apps keep working. Your previous setting is restored afterwards.")
                HStack {
                    Label("Mute speakers", systemImage: "speaker.slash").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Toggle("Mute speakers", isOn: $settings.mute).labelsHidden()
                }.help("Restore your sound when you open the lid.")
                HStack {
                    Label("Protect from overheating", systemImage: "thermometer.medium").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Toggle("Protect from overheating", isOn: $settings.heatProtection).labelsHidden()
                }.help("Use less power if warm. End the session if your Mac gets too hot.")
                HStack {
                    Label("Battery reserve", systemImage: "battery.25percent").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Picker("Stop at battery level", selection: $settings.batteryLimit) {
                        ForEach([10, 15, 20, 30], id: \.self) { Text("\($0)%").tag($0) }
                    }.labelsHidden().frame(width: 72)
                }.help("End Caffeine when your battery falls below this level.")
            }
            .toggleStyle(.switch).tint(.orange).controlSize(.small)
            HStack(spacing: 8) {
                Image(systemName: settings.authorized ? "checkmark.shield" : "lock.shield").foregroundStyle(.orange)
                Text(settings.authorized ? "Ready for lid closed sessions" : "One-time setup needs your Mac’s password")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 3)
                if !settings.authorized {
                    Button(action: enable) {
                        Text(enabling ? "Enabling…" : "Enable").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
                    }.disabled(enabling || manager.isBusy)
                }
                if engine.needsRecovery || engine.message != nil {
                    Button("Restore", action: restore).font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
                }
            }
            .padding(.top, 3)
            Text(setupMessage ?? "Use your Mac on an open, ventilated surface.")
                .font(.system(size: 10)).foregroundStyle(setupMessage == nil ? Color.white.opacity(0.55) : .orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private func enable() {
        enabling = true
        setupMessage = nil
        Task { @MainActor in
            settings.authorized = await engine.authorize()
            enabling = false
            if !settings.authorized { setupMessage = "Setup was cancelled. You can enable it later." }
        }
    }
    private func restore() {
        Task { @MainActor in
            await engine.retryRecovery()
            setupMessage = engine.needsRecovery ? "Keep Caffeine open and try Restore again." : "Your Mac’s settings have been restored."
        }
    }
}
