import Defaults
import SwiftUI

struct NotchTerminalView: View {
    @ObservedObject private var terminal = NotchTerminalManager.shared
    @Default(.terminalApplication) private var preferredApplication
    @EnvironmentObject private var vm: BoringViewModel
    @ViewState private var attachmentEnded = false
    @ViewState private var attachmentID = UUID()
    @ViewState private var copied = false
    @ViewState private var opening = false
    @ViewState private var demandID = UUID()

    private var application: TerminalApplication { .preferred(preferredApplication) }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Label(URL(fileURLWithPath: terminal.directory).lastPathComponent, systemImage: "folder")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1).truncationMode(.middle)
                    .help(terminal.directory)
                Spacer(minLength: 8)
                ForEach(terminal.ports.prefix(3), id: \.self) { port in
                    Button {
                        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(.green).frame(width: 4, height: 4)
                            Text(":\(String(port))").monospacedDigit()
                        }.font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Open localhost:\(port) in your browser")
                    .accessibilityLabel("Open server on port \(port)")
                }
                Menu {
                    ForEach(TerminalApplication.installed) { app in
                        Button("Open in \(app.name)") { open(app) }
                    }
                    Divider()
                    Button("Copy attach command for any terminal") {
                        terminal.copyAttachCommand()
                        copied = true
                    }
                } label: {
                    Label(opening ? "Opening…" : (copied ? "Command copied" : "Open in \(application.name)"),
                          systemImage: copied ? "checkmark" : "arrow.up.right.square")
                        .font(.system(size: 11))
                } primaryAction: {
                    open(application)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!terminal.isRunning || opening)
                .help("Continue this exact shell and its running servers in another terminal")
                Button {
                    vm.close()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Close terminal panel; keep session running")
                    .accessibilityLabel("Close terminal panel")
            }
            .foregroundStyle(.white.opacity(0.85))

            if let error = terminal.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).font(.system(size: 11)).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("Retry") { Task { await terminal.start(force: true); reconnect() } }.buttonStyle(.plain)
                }
                .foregroundStyle(.white.opacity(0.85))
            }

            ZStack {
                Color.clear
                if terminal.isRunning, let tmux = terminal.tmuxPath, !attachmentEnded {
                    EmbeddedTerminalView(tmuxPath: tmux) { attachmentEnded = true }
                        .id(attachmentID)
                        .transaction { $0.animation = nil }
                        .padding(6)
                } else if terminal.isStarting {
                    ProgressView("Starting terminal…").controlSize(.small)
                } else if terminal.error == nil {
                    VStack(spacing: 12) {
                        Text(attachmentEnded ? "Terminal detached" : "Your shell is ready to open")
                            .font(.system(size: 13))
                        Button(attachmentEnded ? "Reconnect" : "Start terminal") {
                            Task { await terminal.start(force: true); reconnect() }
                        }
                    }
                }
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 10))

        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .onAppear { terminal.acquireMetadataDemand(demandID) }
        .onDisappear { terminal.releaseMetadataDemand(demandID) }
        .task { await terminal.start() }
    }

    private func reconnect() {
        attachmentEnded = false
        attachmentID = UUID()
    }

    private func open(_ app: TerminalApplication) {
        opening = true
        copied = false
        Task {
            await terminal.open(in: app)
            opening = false
            if terminal.error == nil { vm.close() }
        }
    }
}
