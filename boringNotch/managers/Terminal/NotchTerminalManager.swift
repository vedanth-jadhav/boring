import AppKit
import Combine
import Defaults

@MainActor
final class NotchTerminalManager: ObservableObject {
    static let shared = NotchTerminalManager()
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var directory = FileManager.default.homeDirectoryForCurrentUser.path
    @Published private(set) var ports: [Int] = []
    @Published var error: String?
    let tmuxPath = TerminalSessionBackend.tmuxPath
    private let backend: TerminalSessionBackend
    private var monitor: Task<Void, Never>?
    private var generation = 0

    var attachCommand: String? {
        tmuxPath.map { TerminalSessionSupport.attachCommand(tmux: $0) }
    }

    init(backend: TerminalSessionBackend = TerminalSessionBackend()) {
        self.backend = backend
        setEnabled(Defaults[.terminalEnabled])
    }

    func setEnabled(_ enabled: Bool) {
        generation += 1
        monitor?.cancel()
        monitor = nil
        if enabled {
            monitorSession()
        } else {
            ports = []
            isStarting = false
        }
    }

    func start(force: Bool = false) async {
        guard Defaults[.terminalEnabled], !isStarting else { return }
        if isRunning && !force { return }
        isStarting = true
        error = nil
        let token = generation
        defer { isStarting = false }
        do {
            try await backend.start()
            guard token == generation, Defaults[.terminalEnabled] else { return }
            // Show the shell immediately; socket/process inspection is background metadata.
            isRunning = true
            monitor?.cancel()
            monitor = nil
            monitorSession()
        } catch {
            if token == generation { self.error = error.localizedDescription }
        }
    }

    private func monitorSession() {
        guard monitor == nil else { return }
        let token = generation
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let snapshot = try await self.backend.snapshot()
                    guard !Task.isCancelled, token == self.generation else { return }
                    self.apply(snapshot)
                    if !snapshot.exists {
                        self.monitor = nil
                        return
                    }
                } catch {
                    guard !Task.isCancelled, token == self.generation else { return }
                    self.error = error.localizedDescription
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func apply(_ snapshot: TerminalSessionSnapshot) {
        if isRunning != snapshot.exists { isRunning = snapshot.exists }
        if directory != snapshot.directory { directory = snapshot.directory }
        if ports != snapshot.ports { ports = snapshot.ports }
    }

    func copyAttachCommand() {
        guard let attachCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(attachCommand, forType: .string)
    }

    func open(in application: TerminalApplication) async {
        guard let attachCommand, let tmuxPath else { return }
        if !isRunning { await start() }
        guard isRunning else { return }
        error = nil
        do {
            try await application.open(command: attachCommand, tmux: tmuxPath)
            Defaults[.terminalApplication] = application.id
        } catch {
            self.error = "Could not open \(application.name). Copy the attach command instead. \(error.localizedDescription)"
        }
    }
}
