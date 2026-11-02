import Foundation

/// The CPU architecture of Linux runner containers. kinhin only runs on
/// Apple Silicon, so `arm64` is native. `amd64` is an explicit opt-in that
/// runs under emulation: Rosetta for Linux on Apple `container`
/// (`container.platform`), or whatever the Docker provider offers
/// (`docker.platform`).
public enum LinuxPlatform: String, Sendable, Equatable, CaseIterable {
    case arm64 = "linux/arm64"
    case amd64 = "linux/amd64"

    /// Name in the GitHub Actions runner release asset
    /// (`actions-runner-linux-<arch>-<version>.tar.gz`).
    public var githubRunnerArch: String { self == .arm64 ? "arm64" : "x64" }

    /// Name in the Gitea runner release asset
    /// (`gitea-runner-<version>-linux-<arch>.xz`).
    public var giteaRunnerArch: String { self == .arm64 ? "arm64" : "amd64" }
    /// gitlab-runner binary suffix ("linux-arm64" / "linux-amd64").
    public var gitlabRunnerArch: String { self == .arm64 ? "arm64" : "amd64" }
    /// Name in the Buildkite agent release asset
    /// (`buildkite-agent-linux-<arch>-<version>.tar.gz`).
    public var buildkiteAgentArch: String { self == .arm64 ? "arm64" : "amd64" }
    /// Platform in the Azure Pipelines agent release asset
    /// (`vsts-agent-<platform>-<version>.tar.gz`).
    public var azureAgentPlatform: String { self == .arm64 ? "linux-arm64" : "linux-x64" }

    /// The architecture label runners register with, replacing the fleet's
    /// default `arm64` label so jobs never land on the wrong architecture.
    public var runnerLabel: String { self == .arm64 ? "arm64" : "x64" }

    /// `docker image inspect --format {{.Architecture}}` for this platform.
    public var dockerArchitecture: String { self == .arm64 ? "arm64" : "amd64" }

    /// Whether this platform runs under emulation on the (Apple Silicon) host.
    public var isEmulated: Bool { self == .amd64 }

    /// Shown wherever `linux/amd64` is chosen (CLI, doctor, checklist, app,
    /// docs) so the trade-off is never a surprise.
    public static let emulationNotice =
        "linux/amd64 runs under emulation on Apple Silicon (Rosetta if enabled in Docker Desktop, "
        + "otherwise QEMU). Expect slower jobs (QEMU can be several times slower), and some software "
        + "fails under emulation: JITs, certain Go/Java/.NET builds, and anything using unsupported CPU "
        + "instructions. Prefer linux/arm64 unless a job needs x86_64. Emulation is provided by your "
        + "Docker provider; kinhin does not configure it."

    /// The Apple `container` counterpart of `emulationNotice`: amd64 containers run their x86_64 code under Rosetta for
    /// Linux, which macOS provides to the container VMs.
    public static let containerEmulationNotice =
        "linux/amd64 runs under Rosetta for Linux on Apple Silicon: slower than arm64, and some software fails under "
        + "it (JITs, certain Go/Java/.NET builds, and anything using CPU instructions Rosetta does not translate, such "
        + "as AVX-512). Prefer linux/arm64 unless a job needs x86_64."

    /// Parses a config or flag value, accepting the bare architecture too.
    public init?(configValue: String) {
        switch configValue.trimmingCharacters(in: .whitespaces).lowercased() {
        case "linux/arm64", "arm64", "aarch64": self = .arm64
        case "linux/amd64", "amd64", "x86_64", "x64": self = .amd64
        default: return nil
        }
    }
}
