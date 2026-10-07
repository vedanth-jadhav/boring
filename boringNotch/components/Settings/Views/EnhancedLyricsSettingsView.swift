import Defaults
import SwiftUI

struct EnhancedLyricsSettingsView: View {
    @StateObject private var model = EnhancedLyricsSettingsModel()
    @Default(.enableEnhancedLyrics) private var enabled
    @Default(.enableLyrics) private var showLyrics
    @ViewState private var showKeyGuide = true

    var body: some View {
        Section {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enhanced word highlighting")
                    Text("Use accurate word timings from Spicy Lyrics when available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!showLyrics || !model.hasSavedKey || model.isBusy)

            LabeledContent("Spicy Lyrics API key") {
                SecureField("API key", text: $model.draftKey,
                            prompt: Text(model.hasSavedKey ? "Paste a replacement key" : "Paste your key"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .disabled(model.isBusy)
                    .onSubmit { if model.canSave { model.saveAndEnable() } }
                    .onChange(of: model.draftKey) { _, key in if !key.isEmpty { model.clearMessage() } }
            }

            HStack(spacing: 10) {
                Button("Save & Enable") { model.saveAndEnable() }
                    .disabled(!model.canSave)
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Text(model.progressText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.hasSavedKey {
                    Button("Remove key", role: .destructive) { model.removeKey() }
                        .disabled(model.isBusy)
                }
            }

            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(model.isError ? Color.red : Color.secondary)
                    .accessibilityLabel(message)
            } else {
                Text(model.hasSavedKey
                     ? (showLyrics ? "Your API key is saved securely in macOS Keychain." : "Turn on Show lyrics above to use your saved key.")
                     : "Add your own API key to enable enhanced lyrics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("How to get an API key", isExpanded: $showKeyGuide) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Open the Spicy Lyrics dashboard and sign in.")
                    Text("2. Create an application for Boring Notch.")
                    Text("3. Copy your secret key and paste it above. Spicy Lyrics shows it only once.")
                    Link("Open Spicy Lyrics dashboard", destination: URL(string: "https://developers.spicylyrics.org/dashboard/applications")!)
                    Link("Read the API key guide", destination: URL(string: "https://developers.spicylyrics.org/docs/keys")!)
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            }
        } header: {
            Text("Enhanced lyrics")
        } footer: {
            Text("Fetches lyric text and timing once per song, then reuses a local cache. Songs without matching word timings use regular lyrics. Turning this off keeps your saved key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            await model.loadStatus()
            if model.hasSavedKey { showKeyGuide = false }
        }
        .onDisappear { model.cancelEditing() }
    }
}
