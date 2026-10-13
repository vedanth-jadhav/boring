import Foundation

struct ShellResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

enum ShellError: Error, LocalizedError {
    case launchFailed(exe: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(exe, underlying):
            return "could not launch \(exe): \(underlying)"
        }
    }
}

/// Minimal async wrapper around `Process`. Never a shell: `exe` is an absolute
/// path and `args` are passed verbatim.
enum Shell {
    private final class PipeBox: @unchecked Sendable {
        let handle: FileHandle
        init(_ handle: FileHandle) { self.handle = handle }
    }

    static func run(_ exe: String, _ args: [String]) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: exe)
                process.arguments = args
                process.standardInput = FileHandle.nullDevice
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                let childExit = ProcessExit(process)

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ShellError.launchFailed(exe: exe, underlying: error.localizedDescription))
                    return
                }

                // Drain both pipes concurrently so neither can fill and block the child.
                let errBox = PipeBox(err.fileHandleForReading)
                let group = DispatchGroup()
                nonisolated(unsafe) var errData = Data()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errData = errBox.handle.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                childExit.wait()

                continuation.resume(returning: ShellResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }
}
