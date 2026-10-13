import Foundation

enum ShellTimeoutError: Error, LocalizedError {
    case timedOut(exe: String, seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case let .timedOut(exe, seconds):
            return "\(exe) did not finish within \(Int(seconds)) s"
        }
    }
}

extension Shell {
    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ p: Process) { process = p }
    }

    /// `Shell.run` with a wall-clock limit. On timeout the child is killed
    /// (SIGTERM, then SIGKILL) and `ShellTimeoutError.timedOut` is thrown.
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) async throws -> ShellResult {
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

                let box = ProcessBox(process)
                let killer = DispatchWorkItem {
                    guard box.process.isRunning else { return }
                    box.process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        if box.process.isRunning { kill(box.process.processIdentifier, SIGKILL) }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

                let group = DispatchGroup()
                nonisolated(unsafe) var errData = Data()
                let errHandle = err.fileHandleForReading
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errData = errHandle.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                childExit.wait()
                let timedOut = !killer.isCancelled && process.terminationReason == .uncaughtSignal
                killer.cancel()

                if timedOut {
                    continuation.resume(throwing: ShellTimeoutError.timedOut(exe: exe, seconds: timeout))
                    return
                }
                continuation.resume(returning: ShellResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }

    /// First existing path among `candidates`, or nil.
    static func locate(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
