import Foundation

// MARK: - Attempts

/// The per-item removals behind ``ResetEverything/execute(_:tart:shell:stopFleet:uninstallDaemon:ensureDirs:)``:
/// like `bestEffort`, but the failure is also reported to the user instead of
/// only logged.
extension ResetEverything {
    /// Step 3's VM and image deletions, one attempt per item, counting only
    /// what was actually removed.
    static func removeVMsAndImages(
        _ cleanup: CleanupPlan, plan: ResetPlan, tart: (any TartControlling)?, report: inout ResetReport
    ) async throws {
        let vms = cleanup.vms + cleanup.scratchVMs
        guard !vms.isEmpty || !cleanup.images.isEmpty else { return }
        let controller: any TartControlling
        if let tart {
            controller = tart
        } else {
            do {
                controller = try TartController(configuredPath: plan.tartPath)
            } catch {
                Log.warn("reset", "tart is not available: \(error.localizedDescription)")
                report.leftBehind.append(
                    "tart is not available (\(error.localizedDescription)); \(vms.count + cleanup.images.count) VM(s)/image(s) were left on disk (re-run `kinhin cleanup --yes`)"
                )
                return
            }
        }
        var removedVMs = 0
        var removedImages = 0
        for vm in vms {
            let removed = try await attemptAsync("delete VM \(vm)", &report) {
                try? await controller.stop(name: vm)  // not running is what we want
                try await controller.delete(name: vm)
            }
            if removed { removedVMs += 1 }
        }
        for image in cleanup.images {
            let removed = try await attemptAsync("delete image \(image)", &report) {
                try await controller.delete(name: image)
            }
            if removed { removedImages += 1 }
        }
        report.completed.append("removed \(removedVMs) VM(s) and \(removedImages) image(s)")
    }

    /// Runs one removal. A failure is logged and lands in `leftBehind` as
    /// "could not <what>: <reason>" instead of stranding the rest of the
    /// reset; cancellation propagates. Returns whether `body` succeeded.
    @discardableResult
    static func attempt(_ what: String, _ report: inout ResetReport, _ body: () throws -> Void) throws -> Bool {
        do {
            try body()
            return true
        } catch let error as CancellationError {
            throw error
        } catch {
            Log.warn("reset", "\(what) failed: \(error.localizedDescription)")
            report.leftBehind.append("could not \(what): \(error.localizedDescription)")
            return false
        }
    }

    /// Async variant of ``attempt(_:_:_:)``.
    static func attemptAsync(
        _ what: String, _ report: inout ResetReport, _ body: () async throws -> Void
    ) async throws -> Bool {
        do {
            try await body()
            return true
        } catch let error as CancellationError {
            throw error
        } catch {
            Log.warn("reset", "\(what) failed: \(error.localizedDescription)")
            report.leftBehind.append("could not \(what): \(error.localizedDescription)")
            return false
        }
    }
}
