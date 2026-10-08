import Foundation

// MARK: - Image, disk and capacity sections

extension DoctorReportBuilder {
    /// The configured tart base image — the same verdict the checklist's
    /// base-image row renders (shared classifier, so they cannot drift). The
    /// checklist already listed tart (and reports a failed listing); an
    /// unreachable tart just leaves known references green and unknown ones
    /// unknown.
    static func tartBaseImageSection(
        config cfg: KinhinConfig?, tartImages: ImageInventory.RuntimeImages?
    ) -> DoctorReport.TartBaseImageSection? {
        guard let cfg, cfg.baseImage != nil else { return nil }
        let verdict = SetupStatusComputer.baseImageState(cfg: cfg, localImages: tartImages)
        return DoctorReport.TartBaseImageSection(
            reference: cfg.baseImage ?? "", state: verdict.state, ok: verdict.ok, fix: verdict.fix,
            pinned: TartBaseImage.isDigestPinned(cfg.baseImage ?? ""),
            warning: SetupStatusComputer.baseImageMutabilityNote(cfg.baseImage))
    }

    /// Image disk usage and the prune suggestion — one build of the same
    /// shared sections `kinhin image list` prints, from the listings this
    /// pass already fetched (one probe set, every surface). The totals are
    /// the sections' `totalGB` (runner VMs and bake scratch VMs are dropped
    /// by name); the suggestion is `ImagePrunePlan.plan` itself, so doctor
    /// can never promise a sweep `kinhin image prune` would refuse. The two
    /// store reads are the ones `image list` makes: they classify derived
    /// images, mark stale records, and (with the fleet) keep in-use images
    /// out of the count.
    func imageSections(
        config cfg: KinhinConfig?, tartImages: ImageInventory.RuntimeImages?,
        containerImages: ImageInventory.RuntimeImages?, dockerImages: ImageInventory.RuntimeImages?
    ) -> (totalGB: [String: Int]?, prune: DoctorReport.ImagePruneSection?) {
        guard let cfg else { return (nil, nil) }
        let fleetRecords = fleet ?? FleetStore().all
        let imageRecords = projectRecords ?? ProjectImageStore().all
        var sections: [ImageInventory.Section] = []
        if let tartImages {
            sections.append(
                ImageInventory.section(
                    .tart, config: cfg, images: tartImages,
                    fleet: fleetRecords, projectRecords: imageRecords))
        }
        if let containerImages {
            sections.append(ImageInventory.section(.container, config: cfg, images: containerImages))
        }
        if let dockerImages {
            sections.append(ImageInventory.section(.docker, config: cfg, images: dockerImages))
        }
        var totals: [String: Int] = [:]
        for section in sections {
            if let gb = section.totalGB { totals[section.runtime.rawValue] = gb }
        }

        let plan = ImagePrunePlan.plan(
            inventory: ImageInventory(sections: sections), config: cfg, fleet: fleetRecords)
        let prunable = plan.targets.filter(\.present)
        let prune =
            prunable.isEmpty
            ? nil
            : DoctorReport.ImagePruneSection(
                count: prunable.count, reclaimGB: plan.reclaimGB, command: "kinhin image prune")
        return (totals.isEmpty ? nil : totals, prune)
    }

    /// Disk pressure — the engine's own pre-spawn guard, computed the same
    /// way (one instance's footprint + the reserve vs free disk), so doctor
    /// warns under exactly the condition that makes the fleet hold spawns —
    /// and the rendered line pairs it with the image totals, because freeing
    /// images is the lever the user has.
    static func diskPressureSection(config cfg: KinhinConfig?, host: HostResources) -> DoctorReport.DiskPressureSection?
    {
        guard let cfg else { return nil }
        let primary = Capacity.primaryRuntime(of: cfg)
        let instanceDisk = ResourceProbe.effectiveDiskPerVMGB(diskGB: cfg.diskGB, runtime: primary.rawValue)
        guard host.freeDiskGB < instanceDisk + cfg.reserve.diskGB else { return nil }
        return DoctorReport.DiskPressureSection(
            freeGB: host.freeDiskGB, runtime: primary.rawValue,
            instanceDiskGB: instanceDisk, reserveGB: cfg.reserve.diskGB)
    }

    /// Capacity — the same math the human doctor prints, plus job slots. The
    /// disk estimate matches the engine's scaler (explicit disk_gb or the
    /// runtime default), so doctor's cap is the cap the fleet enforces.
    static func capacitySection(config cfg: KinhinConfig?, host: HostResources) -> DoctorReport.CapacitySection? {
        guard let cfg else { return nil }
        let plan = Capacity.plan(for: cfg, host: host)
        return DoctorReport.CapacitySection(
            maxConcurrent: plan.maxConcurrent,
            bindingConstraint: plan.bindingConstraint,
            fits: plan.fits,
            jobSlots: plan.maxConcurrent * max(1, cfg.runnersPerVM)
        )
    }
}
