import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct NotificationSettingsView: View {
    @Default(.notificationLiveActivity) private var enabled
    @Default(.notificationsFromAllApps) private var allApps
    @Default(.notificationAllowedApps) private var allowedApps
    @Default(.notificationBlockedApps) private var blockedApps
    @Default(.notificationSuppressNativeBanners) private var suppressNative
    @ObservedObject private var manager = NotificationManager.shared
    @ViewState private var authorized = false
    @ViewState private var requesting = false
    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .notificationLiveActivity) { Text("Enable notification mirroring") }
                LabeledContent("Notification store", value: sourceStatus)
                Button("Open Full Disk Access Settings") { settings("Privacy_AllFiles") }
            } footer: {
                Text("Full Disk Access lets the helper read the macOS notification store. Enable Boring Notch in System Settings, then quit and reopen the app. Notification Center must stay enabled for the apps you capture.")
            }
            Section {
                Defaults.Toggle(key: .notificationSuppressNativeBanners) { Text("Dismiss matching desktop banners") }
                LabeledContent("Accessibility", value: authorized ? "Granted" : "Not granted")
                if suppressNative, !authorized {
                    Button(requesting ? "Waiting for access…" : "Grant Accessibility Access") { grantAccess() }.disabled(requesting)
                }
                Button("Open Accessibility Settings") { settings("Privacy_Accessibility") }
                Button("Open macOS Notification Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }
            } header: { Text("Native banners") } footer: {
                Text("Accessibility enables immediate WhatsApp banner capture and safe dismissal. To prevent duplicate banners completely, turn off Desktop for each captured app in macOS Notifications while keeping Allow Notifications and Notification Center enabled. This system setting also applies while Boring Notch is closed.")
            }
            Section("Privacy") {
                Defaults.Toggle(key: .notificationPreviewPrivacy) { Text("Hide notification previews") }
            }
            appsSection
        }
        .formStyle(.grouped).navigationTitle("Notifications")
        .task { authorized = await XPCHelperClient.shared.isAccessibilityAuthorized() }
        .onReceive(NotificationCenter.default.publisher(for: .accessibilityAuthorizationChanged)) { note in
            if let granted = note.userInfo?["granted"] as? Bool { authorized = granted }
        }
        .onChange(of: allowedApps) { _, _ in manager.updateFilter() }
        .onChange(of: blockedApps) { _, _ in manager.updateFilter() }
        .onChange(of: allApps) { _, _ in manager.updateFilter() }
    }
    private var appsSection: some View {
        Section("Captured apps") {
            Defaults.Toggle(key: .notificationsFromAllApps) { Text("From all apps") }
            if allApps {
                Text("Blocked apps").font(.caption).foregroundStyle(.secondary)
                ForEach(blockedApps.sorted(), id: \.self) { id in NotificationSettingsAppRow(bundleID: id) { blockedApps.remove(id) } }
                Button("Block Application…", systemImage: "plus") { chooseApplication(block: true) }
            } else {
                if allowedApps.isEmpty { Text("No apps selected").foregroundStyle(.secondary) }
                ForEach(allowedApps.sorted(), id: \.self) { id in NotificationSettingsAppRow(bundleID: id) { allowedApps.remove(id) } }
                Button("Add Application…", systemImage: "plus") { chooseApplication(block: false) }
            }
        }.disabled(!enabled)
    }
    private var sourceStatus: String {
        switch manager.availability {
        case .disabled: "Disabled"
        case .starting: "Connecting…"
        case .observing: "Connected"
        case .fullDiskAccessRequired: "Full Disk Access required"
        case .unavailable: "Unavailable"
        case .suspended: "Paused while asleep or locked"
        }
    }
    private func settings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
    private func grantAccess() {
        requesting = true
        Task { authorized = await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true); requesting = false }
    }
    private func chooseApplication(block: Bool) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK else { return }
            let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            Task { @MainActor in if block { blockedApps.formUnion(ids) } else { allowedApps.formUnion(ids) } }
        }
    }
}
private struct NotificationSettingsAppRow: View {
    let bundleID: String
    var remove: () -> Void
    private var name: String { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent ?? bundleID }
    var body: some View {
        HStack {
            appIcon(for: bundleID).resizable().scaledToFit().frame(width: 20, height: 20)
            Text(name); Spacer()
            Button("Remove", role: .destructive, action: remove).buttonStyle(.borderless)
        }
    }
}
