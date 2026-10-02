import Foundation

/// Scans a local checkout (version files, manifests and GitHub workflows) and
/// proposes the `.kinhin.yml` toolchains for it, with the evidence per pick.
public struct ProjectToolchainDetector: Sendable {
    public init() {}

    /// Detects toolchains in the directory at `directory`.
    public func detect(at directory: URL) throws -> ToolchainDetection {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw ConfigError.projectNotFound(directory.path) }
        return try detect(reader: FileSystemProjectReader(root: directory))
    }

    func detect(reader: ProjectFileReading) throws -> ToolchainDetection {
        let probes: [ToolchainProbe] = [VersionFileProbe(), ManifestProbe(), BuildFileVersionProbe(), WorkflowProbe()]
        var hits: [ToolchainHit] = []
        for probe in probes {
            try Task.checkCancellation()
            do {
                hits.append(contentsOf: try probe.hits(in: reader))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One unreadable file must not sink the whole scan.
                Log.warn("Detect", "\(probe.name) probe skipped: \(error.localizedDescription)")
            }
        }
        let xcode = try xcodeSignals(in: reader)
        // Xcode ships its own Swift; a mise Swift would shadow it.
        if !xcode.isEmpty { hits.removeAll { $0.id == "swift" && !$0.isStack } }
        var detection = ToolchainNormalizer.normalize(hits)
        if !xcode.isEmpty {
            detection = ToolchainDetection(
                specs: detection.specs, stacks: detection.stacks,
                evidence: detection.evidence
                    + xcode.map { .init(spec: "xcode (base image)", source: $0.source, reason: $0.reason) },
                unmatched: detection.unmatched, recommendations: [XcodeDetector.recommendation(for: xcode)])
        }
        // Never hand back YAML the engine would reject.
        _ = try ProjectFileLoader.parse(Data(detection.yaml().utf8))
        return detection
    }

    private func xcodeSignals(in reader: ProjectFileReading) throws -> [XcodeDetector.Signal] {
        do {
            return try XcodeDetector.signals(in: reader)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.warn("Detect", "Xcode check skipped: \(error.localizedDescription)")
            return []
        }
    }
}
