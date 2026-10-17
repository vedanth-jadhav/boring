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
    private let metadataPollInterval: Duration
    private var monitor: Task<Void, Never>?
    private var refresh: Task<Void, Never>?
    private var generation = 0
    private var metadataConsumers: Set<UUID> = []

    var attachCommand: String? {
        tmuxPath.map { TerminalSessionSupport.attachCommand(tmux: $0) }
    }

    init(backend: TerminalSessionBackend = TerminalSessionBackend(), metadataPollInterval: Duration = .seconds(5)) {
        self.backend = backend
        self.metadataPollInterval = metadataPollInterval
        setEnabled(Defaults[.terminalEnabled])
    }

    func setEnabled(_ enabled: Bool) {
        generation += 1
        monitor?.cancel()
        monitor = nil
        refresh?.cancel()
        refresh = nil
        if enabled {
            if metadataConsumers.isEmpty {
                refreshSession()
            } else {
                monitorSession()
            }
        } else {
            ports = []
            isStarting = false
        }
    }

    func acquireMetadataDemand(_ id: UUID) {
        guard Defaults[.terminalEnabled], metadataConsumers.insert(id).inserted else { return }
        refresh?.cancel()
        refresh = nil
        monitorSession()
    }

    func releaseMetadataDemand(_ id: UUID) {
        guard metadataConsumers.remove(id) != nil, metadataConsumers.isEmpty else { return }
        generation += 1
        monitor?.cancel()
        monitor = nil
        refresh?.cancel()
        refresh = nil
        isStarting = false
    }

    func start(force _: Bool = false) async {
        guard Defaults[.terminalEnabled], !isStarting else { return }
        generation += 1
        let token = generation
        monitor?.cancel()
        monitor = nil
        refresh?.cancel()
        refresh = nil
        isStarting = true
        isRunning = false
        error = nil
        defer {
            if token == generation {
                isStarting = false
                if !metadataConsumers.isEmpty { monitorSession() }
            }
        }
        do {
            try await backend.start()
            guard token == generation, Defaults[.terminalEnabled] else { return }
            // Show the shell immediately; socket/process inspection is background metadata.
            isRunning = true
        } catch {
            if token == generation { self.error = error.localizedDescription }
        }
    }

    private func monitorSession() {
        guard monitor == nil, !isStarting, Defaults[.terminalEnabled], !metadataConsumers.isEmpty else { return }
        let token = generation
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let snapshot = try await self.backend.snapshot()
                    guard !Task.isCancelled, token == self.generation else { return }
                    self.apply(snapshot)
                } catch {
                    guard !Task.isCancelled, token == self.generation else { return }
                    self.error = error.localizedDescription
                }
                try? await Task.sleep(for: metadataPollInterval)
            }
        }
    }

    private func refreshSession() {
        refresh?.cancel()
        let token = generation
        refresh = Task { [weak self] in
            defer { if self?.generation == token { self?.refresh = nil } }
            guard let self else { return }
            do {
                let snapshot = try await backend.snapshot()
                guard !Task.isCancelled, token == generation, Defaults[.terminalEnabled], metadataConsumers.isEmpty else { return }
                apply(snapshot)
            } catch {
                guard !Task.isCancelled, token == generation, Defaults[.terminalEnabled] else { return }
                self.error = error.localizedDescription
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
