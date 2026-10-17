import Defaults
import SwiftUI

struct TerminalServerIndicator: View {
    @ObservedObject private var terminal = NotchTerminalManager.shared
    @Default(.terminalEnabled) private var enabled
    @ViewState private var demandID = UUID()
    let open: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if enabled && !terminal.ports.isEmpty {
                Button(action: open) {
                    Circle().fill(Color.green.opacity(0.8)).frame(width: 5, height: 5)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Server listening on " + terminal.ports.map(String.init).joined(separator: ", "))
                .accessibilityLabel("Server running in the notch terminal")
                .accessibilityValue(terminal.ports.map(String.init).joined(separator: ", "))
            }
        }
        .onAppear { updateDemand(enabled) }
        .onDisappear { terminal.releaseMetadataDemand(demandID) }
        .onChange(of: enabled) { _, isEnabled in updateDemand(isEnabled) }
    }

    private func updateDemand(_ isEnabled: Bool) {
        if isEnabled {
            terminal.acquireMetadataDemand(demandID)
        } else {
            terminal.releaseMetadataDemand(demandID)
        }
    }
}
