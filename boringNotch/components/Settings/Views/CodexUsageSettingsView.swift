import Defaults
import SwiftUI

struct CodexUsageSettingsView: View {
    @ViewState private var store = CodexUsageStore.shared
    private var preferences = CodexGlancePreferences()
    @Default(.codexActivityConflict) private var conflict
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            Section {
                Picker("Stats & glance account", selection: $store.provider) {
                    ForEach(AIUsageProvider.allCases) { provider in Text(provider.title).tag(provider) }
                }
                ForEach(AIUsageProvider.allCases) { provider in
                    HStack(spacing: 12) {
                        if provider == .codex { CodexLogo().frame(width: 22, height: 22) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(provider.title).fontWeight(.medium)
                            Text(store.connectionMessages[provider] ?? "Not connected")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.connecting.contains(provider) {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { store.cancelSignIn(provider) }
                        } else {
                            Button("Sign in") { store.connect(provider) }
                                .accessibilityLabel("Sign in to \(provider.accountTitle) in your browser")
                            Button("Disconnect") { Task { await store.disconnect(provider) } }
                                .accessibilityLabel("Disconnect \(provider.title)")
                        }
                    }
                }
            } header: { Text("Accounts") }
              footer: { Text("Sign in securely in your default browser. The service returns tokens to Boring Notch, which keeps them privately on this Mac and renews them as needed. Disconnect removes only this app’s connection.") }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your allowance, at a glance.").font(.headline)
                    CodexUsageSettingsPreview(provider: store.provider, display: preferences.display, outside: preferences.outside, inside: preferences.inside)
                    Text("Illustrative preview").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                Picker("Display", selection: preferences.$display) {
                    ForEach(CodexUsageDisplay.allCases) { option in Text(option.title).tag(option) }
                }
                .pickerStyle(.segmented)
                Text(preferences.display == .pill
                     ? "A small glass pill beside the notch, with text beside Settings when it opens."
                     : preferences.display == .text
                     ? "A quiet reading beside Settings in the open notch."
                     : "Open the AI Usage tab to see your usage.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: { Text("Placement") }

            if preferences.display == .pill {
                Section {
                    if store.provider == .grok { Text("Plan credits") }
                    else {
                        Picker("Limit", selection: preferences.$outsideLimit) {
                            ForEach(CodexPillLimit.allCases) { option in Text(option.title).tag(option) }
                        }
                    }
                    Picker("Show", selection: preferences.$outsideMetric) {
                        ForEach(CodexPillMetric.allCases) { option in Text(option.title).tag(option) }
                    }
                    Toggle("Show limit label", isOn: preferences.$outsideShowsLabel)
                } header: { Text("Outside the notch") }
            }

            if preferences.display != .off {
                Section {
                    if preferences.display == .pill {
                        Toggle("Match the pill", isOn: preferences.$insideMatchesPill)
                    }
                    if preferences.display == .text || !preferences.insideMatchesPill {
                        if store.provider == .grok { Text("Plan credits") }
                        else {
                            Picker("Limit", selection: preferences.$insideLimit) {
                                ForEach(CodexPillLimit.allCases) { option in Text(option.title).tag(option) }
                            }
                        }
                        Picker("Show", selection: preferences.$insideMetric) {
                            ForEach(CodexPillMetric.allCases) { option in Text(option.title).tag(option) }
                        }
                        Toggle("Show limit label", isOn: preferences.$insideShowsLabel)
                    }
                } header: { Text("Inside the notch") }
                  footer: {
                      Text(preferences.display == .pill && preferences.insideMatchesPill
                           ? "Uses the same limit and reading as the pill. Turn off to choose a different reading inside."
                           : "Choose the inside reading separately. Hover for full usage and reset times when space is limited.")
                  }
            }

            if preferences.display == .pill {
                Section {
                    Picker("Timer & caffeine", selection: $conflict) {
                        ForEach(CodexActivityConflict.allCases) { option in Text(option.title).tag(option) }
                    }
                } header: { Text("With an active session") }
                  footer: {
                      Text(conflict == .oppositeSides
                           ? "Usage stays on the right; timer stays on the left. Both remain visible."
                           : "Hides the usage pill while a timer runs. Its reading remains inside the open notch.")
                  }
            }

            Section {
                Text("Saved automatically. Refreshes about every 30 seconds while connected (60 seconds for Antigravity), and immediately when the notch opens. Saved or unavailable readings are marked; click for details or to retry.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI Usage")
        .tint(.effectiveAccent)
        .animation(reduceMotion ? nil : StandardAnimations.focusTab, value: preferences.display)
        .animation(reduceMotion ? nil : StandardAnimations.focusTab, value: preferences.insideMatchesPill)
        .task { await store.loadConnectionStates() }
        .onAppear { updateMonitoring() }
        .onChange(of: preferences.display) { updateMonitoring() }
    }

    private func updateMonitoring() {
        CodexUsageStore.shared.setGlanceMonitoring(enabled: preferences.display != .off)
    }
}
