import Foundation
import OrchardKit

enum DoctorCommand {
    static func run(_ args: [String]) async {
        Paths.ensureSupportDirectories()
        print("Orchard doctor")
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
                        print("  cont image: \(wanted) NOT LOCAL — prepare with: orchard image prepare --container --target \(wanted)")
                    }
                }
            case .missing:
                print("  container:  NOT FOUND ✗ — install with: brew install --cask container && container system start")
            case .broken(let why):
                print("  container:  \(why)")
            default:
                break
            }
        }
        print("  token:      \(KeychainTokenStore.load() != nil ? "stored ✓" : "missing — run: orchard auth set")")
        let configExists = FileManager.default.fileExists(atPath: Paths.config.path)
        print("  config:     \(configExists ? Paths.config.path : "missing — run: orchard config init")")
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
            print("  job slots:  up to \(plan.maxConcurrent * max(1, cfg.runnersPerVM)) concurrent jobs (\(plan.maxConcurrent) VM(s) × runners_per_vm \(max(1, cfg.runnersPerVM)))")
            if !plan.fits {
                print("  WARNING: a single VM does not fit the host within reserved headroom")
            }
            print("  image:      \(cfg.image)")
            if !cfg.repo.contains("/") {
                print("  scope:      organization '\(cfg.repo)' — runners serve every repo; PAT needs org runner permissions (admin:org)")
                // Active verification: mint (and discard) a registration token —
                // the exact call the fleet's lifecycle depends on.
                if let token = KeychainTokenStore.load() {
                    let client = GitHubClient(credentials: GitHubCredentials(token: token, scope: cfg.repo))
                    let report = await OrgPermissionProbe.verify(github: client, scope: cfg.repo)
                    print("  org perms:  \(report.message)")
                } else {
                    print("  org perms:  cannot verify — no token stored (run: orchard auth set)")
                }
            }
        }
    }
}
