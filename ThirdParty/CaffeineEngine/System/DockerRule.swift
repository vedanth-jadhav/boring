import Foundation

/// Spec section 4, Docker rule: if Docker Desktop is running and has no
/// running containers, it is frozen like any other app (bypassing its
/// denylist entry). Any error means Docker is left alone.
///
/// The rule only *decides*; `LidActions` journals `dockerFrozen` and the
/// pids before the group is actually stopped.
///
/// The idle answer is a snapshot, so `LidActions` asks twice: once to pick
/// Docker up (`idleDockerGroup`) and once more right before the SIGSTOP
/// (`isStillIdle`), after the journal write, with only the per-pid kernel
/// lookups left between the answer and the signal. A container that starts
/// inside that last window is still frozen along with Desktop; nothing in
/// this process can close it, which is why the rule is off by default.
struct DockerRule: Sendable {
    static let bundleId = FreezePlanner.dockerBundleId
    static let timeout: TimeInterval = 5

    static let dockerCandidates: [String] = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "\(NSHomeDirectory())/.docker/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
    ]

    /// Docker Desktop's own engine socket. The probe binds to it with
    /// `--host`, which the CLI ranks above `DOCKER_HOST`, `DOCKER_CONTEXT`
    /// and `docker context use`, so an ambient remote or empty daemon cannot
    /// answer for the local Desktop that is about to be frozen.
    static let desktopSocket = "\(NSHomeDirectory())/.docker/run/docker.sock"

    struct EndpointError: Error, LocalizedError, Sendable {
        let path: String
        let reason: String
        var errorDescription: String? { "docker endpoint \(path): \(reason)" }
    }

    /// Runs `docker ps -q` and returns true only on a clean, empty answer.
    typealias ContainerProbe = @Sendable () async throws -> Bool

    let freezer: any Freezing
    let probe: ContainerProbe

    init(freezer: any Freezing, probe: ContainerProbe? = nil) {
        self.freezer = freezer
        self.probe = probe ?? DockerRule.liveProbe
    }

    /// The Docker Desktop process tree if it is running *and* idle, else nil.
    func idleDockerGroup(config: Config) async -> FreezeGroup? {
        guard config.dockerRule else { return nil }
        let groups = freezer.plan(bundleIds: [Self.bundleId], config: config, applyDenylist: false)
        guard let docker = groups.first else { return nil }
        do {
            let idle = try await probe()
            guard idle else {
                Log.info("docker rule: first check found containers running, Docker left alone")
                return nil
            }
            Log.info("docker rule: first check found no running container")
            return docker
        } catch {
            Log.error("docker rule: first check failed, Docker left alone: \(error.localizedDescription)")
            return nil
        }
    }

    /// The second check. True only when the probe answers idle again; busy,
    /// a failed probe and a timeout all return false. Every answer of both
    /// checks gets its own log line, so a release check can read which
    /// probe saw what.
    func isStillIdle() async -> Bool {
        do {
            let idle = try await probe()
            Log.info(idle ? "docker rule: second check found no running container" : "docker rule: second check found containers running, Docker left alone")
            return idle
        } catch {
            Log.error("docker rule: second check failed, Docker left alone: \(error.localizedDescription)")
            return false
        }
    }

    /// `unix://` URL for `socketPath` once it is known to be a Unix socket.
    /// Throws otherwise, so the caller leaves Docker alone rather than let
    /// the CLI fall back to whatever daemon the environment points at.
    static func verifiedDesktopHost(socketPath: String = desktopSocket) throws -> String {
        let type: FileAttributeType?
        do {
            type = try FileManager.default.attributesOfItem(atPath: socketPath)[.type] as? FileAttributeType
        } catch {
            throw EndpointError(path: socketPath, reason: "not found (\(error.localizedDescription))")
        }
        guard type == .typeSocket else {
            throw EndpointError(path: socketPath, reason: "not a Unix socket")
        }
        return "unix://\(socketPath)"
    }

    static func probeArguments(host: String) -> [String] {
        ["--host", host, "ps", "-q"]
    }

    /// True when `docker --host <desktop socket> ps -q` succeeds and prints nothing.
    static let liveProbe: ContainerProbe = makeProbe()

    /// `docker` nil means the first of `dockerCandidates` found at call time.
    static func makeProbe(docker: String? = nil, socketPath: String = desktopSocket) -> ContainerProbe {
        {
            guard let docker = docker ?? Shell.locate(dockerCandidates) else {
                throw ShellError.launchFailed(exe: "docker", underlying: "not found in \(dockerCandidates.joined(separator: ", "))")
            }
            let host = try verifiedDesktopHost(socketPath: socketPath)
            let r = try await Shell.run(docker, probeArguments(host: host), timeout: timeout)
            guard r.succeeded else {
                throw SleepGuardError(command: "docker --host \(host) ps -q", status: r.status, stderr: r.stderr)
            }
            return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
