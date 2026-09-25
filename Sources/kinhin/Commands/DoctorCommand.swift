import Foundation
import KinhinKit

enum DoctorCommand {
    /// Builds and prints the machine-readable diagnostics document, returning
    /// exactly the data it printed so tests can decode the emitted contract.
    /// `builder` is injectable: the live default probes the real machine,
    /// tests pass a fully-fixture builder (no Keychain, subprocess, network).
    static func emitJSON(builder: DoctorReportBuilder = DoctorReportBuilder()) async throws -> (
        report: DoctorReport, data: Data
    ) {
        let report = await builder.build()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        print(String(decoding: data, as: UTF8.self))
        return (report, data)
    }

    static func run(_ args: [String]) async throws {
        Paths.ensureSupportDirectories()
        // Machine output first: the whole point is a one-shot diagnostics
        // document for scripts — nothing else is printed in this mode.
        if args.contains("--json") {
            _ = try await Self.emitJSON()
            return
        }
        print("kinhin doctor")
        print("  macOS:      \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let arch = ResourceProbe().snapshot()
        print("  arch:       \(arch.arm64 ? "arm64 ✓" : "NOT arm64 — Tart requires Apple Silicon ✗")")
        print("  cores:      \(arch.logicalCores)")
        print("  memory:     \(arch.memoryGB) GB")
        print("  free disk:  \(arch.freeDiskGB) GB")
        let clt = await CLTProbe().check()
        switch clt {
        case .ok(let version):
            print("  clt:        Command Line Tools \(version) ✓")
        case .outdated(let version, let macOS):
            print("  clt:        OUTDATED ✗ (\(version) < macOS \(macOS)) — Homebrew will refuse to build")
            print("  clt fix:    \(CLTRepair.commandLine)")
            print("              \(CLTRepair.fallbackHint)")
        case .missing:
            print("  clt:        NOT INSTALLED ✗ — Homebrew needs it to build from source")
            print("  clt fix:    \(CLTRepair.commandLine)")
        case .unselected:
            print("  clt:        xcode-select points nowhere ✗ — reinstall, then re-select")
            print("  clt fix:    \(CLTRepair.commandLine)")
        }
        let tartHealth = await TartHealthProbe().check()
        switch tartHealth {
        case .healthy:
            print("  tart:       installed and launches ✓")
        case .missing:
            let repair = TartHealthProbe.repairs(for: .missing)[0]
            print("  tart:       NOT FOUND — install with: \(repair.commandLine)")
        case .killedOnLaunch:
            print("  tart:       INSTALLED BUT KILLED ON LAUNCH ✗ (Gatekeeper/notarization — openai/homebrew-tools#27)")
            print("  tart fix:   roll back to the notarized Cirrus Labs build:")
            for repair in TartHealthProbe.repairs(for: .killedOnLaunch) {
                print("              [\(repair.title)]")
                print("                \(repair.commandLine)")
            }
        case .broken(let reason):
            print("  tart:       BROKEN ✗ (\(reason))")
            print("  tart fix:   reinstall, or roll back to the notarized Cirrus Labs build:")
            for repair in TartHealthProbe.repairs(for: tartHealth) {
                print("              [\(repair.title)]")
                print("                \(repair.commandLine)")
            }
        }
        // Apple-container runtime — shown only when the config enables it.
        if let cfg = try? ConfigLoader.load(), cfg.container != nil {
            let health = await AppleContainerRuntime().health()
            switch health {
            case .ready:
                print("  container:  apple container ready ✓ (Linux microVM runners)")
                if let cfg = try? ConfigLoader.load(), let wanted = cfg.container?.image {
                    let runtime = AppleContainerRuntime()
                    let names = await runtime.localImageNames()
                    if names.contains(where: { $0 == wanted || $0.hasPrefix("\(wanted):") }) {
                        print("  cont image: \(wanted) ✓")
                    } else {
                        print(
                            "  cont image: \(wanted) NOT LOCAL — prepare with: kinhin image prepare --container --target \(wanted)"
                        )
                    }
                }
            case .missing:
                print("  container:  NOT FOUND ✗ — install with: brew install container && container system start")
            case .broken(let why):
                print("  container:  \(why)")
            default:
                break
            }
        }
        let doctorConfig = try? ConfigLoader.load()
        if doctorConfig?.githubEnabled ?? true {
            print("  token:      \(KeychainTokenStore.load() != nil ? "stored ✓" : "missing — run: kinhin auth set")")
        }
        if doctorConfig?.gitea != nil {
            print(
                "  gitea tok:  \(KeychainTokenStore.load(forge: .gitea) != nil ? "stored ✓" : "missing — run: kinhin auth set --gitea")"
            )
        }
        for account in doctorConfig?.accounts ?? [] {
            let stored = KeychainTokenStore.load(forge: account.forge, name: account.name) != nil
            print(
                "  \(("tok " + account.name + ":").padding(toLength: 11, withPad: " ", startingAt: 0))"
                    + (stored ? "stored ✓" : "missing — run: kinhin auth set --account \(account.name)"))
        }
        let configExists = FileManager.default.fileExists(atPath: Paths.config.path)
        print("  config:     \(configExists ? Paths.config.path : "missing — run: kinhin config init")")
        // Shared toolchain cache: what prepare writes through and runner
        // VMs/containers bind when share_cache is on. The selected-ecosystem
        // breakdown mirrors the JSON document's `toolchainCache` section.
        let cacheConfig = (try? ConfigLoader.load()).flatMap { $0 }
        let cache = DoctorReportBuilder.toolchainCacheSection(config: cacheConfig)
        let shareCacheOn = cacheConfig?.toolchains?.shareCache ?? false
        if cache.usable {
            let gb = Double(cache.totalBytes) / 1_073_741_824
            let detail = cache.ecosystems.map {
                "\($0.directory) \(String(format: "%.1f", Double($0.bytes) / 1_048_576)) MB"
            }.joined(separator: ", ")
            print(
                "  cache:      \(String(format: "%.1f", gb)) GB at \(cache.root) ✓\(detail.isEmpty ? " (empty)" : " — \(detail)")"
            )
            if shareCacheOn, cache.totalBytes == 0 {
                print(
                    "  cache note: share_cache is on but the cache is empty — runners will mount an empty dir until a prepare populates it"
                )
            }
        } else {
            print(
                "  cache:      NOT USABLE ✗ at \(cache.root) — the next prepare recreates it\(shareCacheOn ? " (share_cache is on: runner mounts will be empty)" : "")"
            )
        }
        if configExists, let cfg = try? ConfigLoader.load() {
            let plan = Capacity.plan(
                host: arch,
                vmCPU: cfg.vm.cpuCount,
                vmMemoryGB: cfg.vm.memoryGB,
                reservedCPU: cfg.reserve.cpu,
                reservedMemoryGB: cfg.reserve.memoryGB,
                diskPerVMGB: cfg.diskGB ?? 0,
                userMax: cfg.maxRunners
            )
            print("  capacity:   up to \(plan.maxConcurrent) concurrent VM(s) (binding: \(plan.bindingConstraint))")
            print(
                "  job slots:  up to \(plan.maxConcurrent * max(1, cfg.runnersPerVM)) concurrent jobs (\(plan.maxConcurrent) VM(s) × runners_per_vm \(max(1, cfg.runnersPerVM)))"
            )
            if !plan.fits {
                print("  WARNING: a single VM does not fit the host within reserved headroom")
            }
            print("  image:      \(cfg.image)")
            if cfg.githubEnabled, !cfg.repo.contains("/") {
                print("  scope:      organization '\(cfg.repo)' — runners serve every repo")
                print(
                    TokenRequirements.github(scope: cfg.repo).plainText
                        .split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
                // Active verification: mint (and discard) a registration token —
                // the exact call the fleet's lifecycle depends on.
                if let token = KeychainTokenStore.load() {
                    let client = GitHubClient(credentials: GitHubCredentials(token: token, scope: cfg.repo))
                    let report = await OrgPermissionProbe.verify(github: client, scope: cfg.repo)
                    print("  org perms:  \(report.message)")
                } else {
                    print("  org perms:  cannot verify — no token stored (run: kinhin auth set)")
                }
            }
        }
    }
}
