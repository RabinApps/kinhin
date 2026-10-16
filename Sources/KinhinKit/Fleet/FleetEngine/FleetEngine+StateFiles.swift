import Foundation

// MARK: - Corrupt state files

extension FleetEngine {
    /// Raises a status alert for each state file that was unreadable and set
    /// aside (see `StateFile`), so the app and `kinhin status` show the loss
    /// instead of only the log. Run at recovery, after the store's reload.
    func surfaceCorruptStateFiles() async {
        let fleet = store.recoveredFromCorruptFile.map {
            "fleet.json was unreadable, so kinhin started without its VM records (job and repo attribution is lost); "
                + "the unreadable file is kept at \($0.path)"
        }
        let images = projectStore.recoveredFromCorruptFile.map {
            "project-images.json was unreadable, so kinhin forgot which per-project images it built (they are no "
                + "longer pruned); the unreadable file is kept at \($0.path)"
        }
        guard fleet != nil || images != nil else { return }
        await statusBox.modify { status in
            if let fleet { status.setAlert("store:fleet", fleet) }
            if let images { status.setAlert("store:project-images", images) }
        }
    }
}
