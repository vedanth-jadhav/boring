import Defaults
import SwiftUI

struct CodexUsageSettingsView: View {
    private var preferences = CodexGlancePreferences()
    @Default(.codexActivityConflict) private var conflict
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your allowance, at a glance.").font(.headline)
                    CodexUsageSettingsPreview(display: preferences.display, outside: preferences.outside, inside: preferences.inside)
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
                     : "Open the Codex tab to see your usage.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: { Text("Placement") }

            if preferences.display == .pill {
                Section {
                    Picker("Limit", selection: preferences.$outsideLimit) {
                        ForEach(CodexPillLimit.allCases) { option in Text(option.title).tag(option) }
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
                        Picker("Limit", selection: preferences.$insideLimit) {
                            ForEach(CodexPillLimit.allCases) { option in Text(option.title).tag(option) }
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
                           ? "Codex stays on the right; timer stays on the left. Both remain visible."
                           : "Hides the Codex pill while a timer runs. Its reading remains inside the open notch.")
                  }
            }

            Section {
                Text("Saved automatically. Refreshes about every 5 seconds while connected, and immediately when the notch opens. Saved or unavailable readings are marked; click for details or to retry.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Codex")
        .tint(.effectiveAccent)
        .animation(reduceMotion ? nil : StandardAnimations.focusTab, value: preferences.display)
        .animation(reduceMotion ? nil : StandardAnimations.focusTab, value: preferences.insideMatchesPill)
        .onAppear { updateMonitoring() }
        .onChange(of: preferences.display) { updateMonitoring() }
    }

    private func updateMonitoring() {
        CodexUsageStore.shared.setGlanceMonitoring(enabled: preferences.display != .off)
    }
}
