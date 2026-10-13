import AppKit

enum TerminalApplication: String, CaseIterable, Identifiable {
    case terminal = "com.apple.Terminal"
    case ghostty = "com.mitchellh.ghostty"
    case iTerm = "com.googlecode.iterm2"

    var id: String { rawValue }
    var name: String {
        switch self {
        case .terminal: return "Terminal"
        case .ghostty: return "Ghostty"
        case .iTerm: return "iTerm2"
        }
    }

    @MainActor var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue)
    }

    @MainActor static var installed: [Self] { allCases.filter { $0.applicationURL != nil } }

    @MainActor static func preferred(_ saved: String) -> Self {
        let preference = Self(rawValue: saved) ?? .terminal
        return preference.applicationURL == nil ? .terminal : preference
    }

    @MainActor func open(command: String, tmux: String) async throws {
        guard let applicationURL else {
            throw NSError(domain: "NotchTerminal", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "\(name) is not installed."])
        }
        let arguments: [String]
        switch self {
        case .ghostty:
            arguments = ["-n", "-a", applicationURL.path, "--args", "-e", tmux,
                         "-L", TerminalSessionSupport.socketName, "attach-session", "-t",
                         TerminalSessionSupport.sessionName]
        case .terminal, .iTerm:
            let script = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Boring Notch/Terminal/Attach.command")
            try ("#!/bin/sh\nexec " + command + "\n").write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            arguments = ["-a", applicationURL.path, script.path]
        }
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardError = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "NotchTerminal", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: String(decoding: output, as: UTF8.self)])
            }
        }.value
    }
}
