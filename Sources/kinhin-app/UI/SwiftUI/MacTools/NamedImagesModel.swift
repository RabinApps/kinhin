import Foundation
import KinhinKit
import Observation

/// The "More images" block of the "This Mac" form: extra named macOS tart
/// images (`images:` in config.yaml), each with a base image and the labels
/// that select it. Edits write the config through `ImagesConfigEditor` and
/// ask the owning form to reload; bakes run through its `InstallCoordinator`.
@MainActor
@Observable
final class NamedImagesModel {
    /// One extra named macOS image, with whether its VM is prepared.
    struct Row: Identifiable, Equatable {
        var name: String
        var baseImage: String?
        var labels: [String] = []
        var present: Bool
        var id: String { name }
    }

    var rows: [Row] = []

    @ObservationIgnored private unowned let owner: MacToolsModel

    init(owner: MacToolsModel) {
        self.owner = owner
    }

    /// Adds an `images:` entry (a name and its base, e.g. a Cirrus `-xcode` image).
    func add(name: String, baseImage: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        mutate { $0.append(.init(name: trimmed, baseImage: baseImage)) }
    }

    func setBase(_ baseImage: String?, for name: String) {
        mutate { images in
            if let index = images.firstIndex(where: { $0.name == name }) { images[index].baseImage = baseImage }
        }
        owner.installs.busyLine = StatusLine(text: "Base image saved. Rebuild '\(name)' for it to take effect.")
    }

    /// Sets the labels a job requests (`runs-on`) to run on this image; empty = not selectable by label.
    func setLabels(_ text: String, for name: String) {
        let labels = text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        // Focus loss commits too: skip the config write (and engine restart) when nothing changed.
        guard rows.first(where: { $0.name == name })?.labels != labels else { return }
        mutate { images in
            if let index = images.firstIndex(where: { $0.name == name }) {
                images[index].labels = labels.isEmpty ? nil : labels
            }
        }
    }

    /// Removes the entry from the config. The prepared VM (large) stays on disk; say so.
    func remove(_ name: String) {
        mutate { $0.removeAll { $0.name == name } }
        owner.installs.busyLine = StatusLine(
            text: "Removed '\(name)' from the config. Its prepared VM is still on disk (tart delete \(name)).")
    }

    func prepare(_ name: String) {
        let present = rows.first(where: { $0.name == name })?.present ?? false
        if present,
            !owner.seams.confirmRebuild(
                "Rebuild image “\(name)”?",
                "This replaces the existing image with a fresh bake from its base image and takes a while.")
        {
            return
        }
        owner.installs.run(
            "Preparing image “\(name)” — this takes a while…",
            cancelledLine: "Cancelled — the previous image is untouched"
        ) {
            try await ImageBuildService.rebuild(.tart, config: ConfigLoader.load(), image: name)
        }
    }

    private func mutate(_ change: (inout [KinhinConfig.ImageConfig]) -> Void) {
        do {
            var images = try ConfigStore.snapshot(at: owner.configURL)?.images ?? []
            change(&images)
            try ImagesConfigEditor.apply(images, to: owner.configURL)
            owner.reload()
            owner.onChanged?()
        } catch {
            owner.installs.busyLine = .notSaved(error)
        }
    }
}
