import Foundation

/// Creates a Linux tart VM from scratch — the `tart create --linux` path from
/// the Tart quick start — for hosts that want to build their own base image
/// instead of cloning a prepared one (Cirrus Labs publishes arm64 images only,
/// and some fleets need a custom OS build).
///
/// A freshly created Linux VM has no operating system: kinhin creates the VM,
/// optionally boots it once with install media attached (an arm64 ISO as a
/// second disk), and hands the interactive OS install to the user. Once the
/// guest has an OS and an `admin` user, the existing `kinhin image prepare
/// --source <vm>` finishes the job (runner agents, toolchains, target image).
public struct TartLinuxVMCreator {
    let tart: TartControlling

    public init(tart: TartControlling) {
        self.tart = tart
    }

    public struct Options {
        /// Name for the new VM. It later becomes the `--source` of an
        /// `image prepare`, so pick the name you want the base image to have.
        public var name: String
        /// Host path to an arm64 install ISO (e.g.
        /// `focal-desktop-arm64.iso`). When set, the VM boots once with the
        /// ISO attached as a second disk so the user can install the OS.
        /// nil boots the empty VM (UEFI shell) — only useful with network or
        /// recovery installs.
        public var isoPath: String?
        /// A pre-configured tart image to start from instead of an empty VM
        /// (see `TartBaseImage.curated` — the quick-start's "VM images").
        /// The published images already have an OS and the admin user, so no
        /// install step is needed. Takes precedence over `isoPath`.
        public var from: String?

        public init(name: String, isoPath: String? = nil, from: String? = nil) {
            self.name = name
            self.isoPath = isoPath
            self.from = from
        }
    }

    /// Creates the VM and, when an ISO is given, boots it with the install
    /// media attached. Never touches an existing VM — a name collision fails
    /// before anything is created.
    public func run(_ options: Options) async throws {
        // Validate everything BEFORE creating the VM: a bad ISO must not leave
        // an empty VM behind, and an existing name must never be clobbered.
        if try await tart.list().contains(where: { $0.name == options.name }) {
            throw ImageError.provisioningFailed(
                "a VM named '\(options.name)' already exists — pick another name, or delete the old one first: tart delete \(options.name)"
            )
        }
        var options = options
        if let iso = options.isoPath {
            let expanded = ImagePreparer.expandingTilde(in: iso)
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw ImageError.provisioningFailed("install ISO '\(expanded)' does not exist")
            }
            options.isoPath = expanded
        }

        // Pre-configured start: `tart clone` (which pulls implicitly) puts a
        // ready-to-use OS on the target name — no install step, no rollback
        // window beyond the clone itself.
        if let from = options.from {
            if let problem = TartBaseImage.problem(with: from) {
                throw ImageError.provisioningFailed("source image \(problem)")
            }
            Log.info("image", "cloning pre-configured image \(from) to '\(options.name)'")
            try await tart.clone(source: from, to: options.name)
            Log.info(
                "image",
                "'\(options.name)' is ready — bake the runner agents with: kinhin image prepare --source \(options.name)"
            )
            return
        }

        Log.info("image", "creating Linux VM '\(options.name)' (tart create --linux)")
        try await tart.createLinux(name: options.name)
        do {
            if let iso = options.isoPath {
                Log.info("image", "booting '\(options.name)' with install media \(iso)")
                try await tart.runWithDisk(name: options.name, isoPath: iso)
                Log.info(
                    "image",
                    "finish the OS install in the VM window (create an 'admin' user, let Tart's SSH key in), then run: kinhin image prepare --source \(options.name)"
                )
            } else {
                Log.info("image", "booting '\(options.name)' (no OS attached yet)")
                try await tart.run(name: options.name)
                Log.info(
                    "image",
                    "the VM booted into its firmware with no OS. Re-create with --iso <arm64.iso> to attach install media, install the OS, then run: kinhin image prepare --source \(options.name)"
                )
            }
        } catch {
            // Never leave a half-created VM behind: the boot failed, so the
            // user has nothing to install into.
            await bestEffortAsync("image", "deleting the unusable VM '\(options.name)'") {
                try await tart.delete(name: options.name)
            }
            throw error
        }
        Log.info("image", "Linux VM '\(options.name)' is ready for its OS install")
    }
}
