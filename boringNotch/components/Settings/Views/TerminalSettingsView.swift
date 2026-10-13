import Defaults
import SwiftUI

struct TerminalSettingsView: View {
    @Default(.terminalEnabled) private var enabled
    @Default(.terminalApplication) private var application
    @ObservedObject private var terminal = NotchTerminalManager.shared

    var body: some View {
        Form {
            Section {
                Toggle("Enable terminal in the notch", isOn: $enabled)
            } footer: {
                Text("Run your shell, developer tools, and servers in the Terminal tab. Turning this off hides the tab and stops monitoring; existing commands keep running.")
            }
            Section {
                Picker("Preferred terminal", selection: $application) {
                    ForEach(TerminalApplication.installed) { app in
                        Text(app.name).tag(app.id)
                    }
                }
                Button("Copy attach command") { terminal.copyAttachCommand() }
                    .disabled(!terminal.isRunning)
            } header: {
                Text("Continue in another app")
            } footer: {
                Text("The dropdown opens the same live session in Terminal, Ghostty, or iTerm2. Your choice is remembered. Paste the attach command into any other terminal app.")
            }
            Section {
                LabeledContent("Status", value: terminal.isRunning ? "Running" : "Starts when you open the tab")
                if !terminal.ports.isEmpty {
                    LabeledContent("Listening ports", value: terminal.ports.map(String.init).joined(separator: ", "))
                }
                if terminal.tmuxPath == nil {
                    Text("Install tmux with brew install tmux to enable persistent sessions.")
                        .textSelection(.enabled)
                }
            } header: {
                Text("Session")
            } footer: {
                Text("A small green dot appears while a server in this session is listening. Stop servers with Control-C or exit the shell to end the session. Sessions survive app relaunches, until you log out or restart your Mac.")
            }
        }
        .onAppear {
            application = TerminalApplication.preferred(application).id
        }
    }
}
