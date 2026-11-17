import CryptoKit
import Foundation

/// What the Docker Hub cache (`DockerRegistryCache`) keeps on disk, checked from the host. `registry:3` stores each
/// blob once (`docker/registry/v2/blobs/sha256/<ab>/<digest>/data`) and gives every repository a small link file per
/// layer and manifest it serves (`repositories/<name>/_layers/sha256/<digest>/link`). When the proxy TTL expires a
/// blob, the registry deletes the blob itself, but other repositories' links to it stay. A pull of any of those
/// repositories then gets the layer as an empty or truncated response (`unexpected EOF`) instead of a fresh fetch from
/// Docker Hub. A link with no blob, or a blob whose data is empty when its digest is not the empty digest, is such a
/// broken entry. Deleting it makes the registry fetch the layer from Docker Hub again on the next pull.
///
/// Pure file-system work on the bind-mounted data directory, so it runs (and is tested) without the container. It
/// is safe while the registry runs: the registry writes a blob's data before any link to it, so a link never points at
/// a blob that is still on its way.
enum DockerRegistryCacheStorage {
    /// The sha256 of no bytes: the one digest whose blob is legitimately empty.
    static let emptyDigest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// What a scan found.
    struct Report: Equatable, Sendable {
        /// Link files checked (layers, manifest revisions and tags).
        var links = 0
        /// Blobs checked.
        var blobs = 0
        /// Links whose blob is missing or broken, as paths under the data directory.
        var danglingLinks: [String] = []
        /// Blobs whose data is missing or empty when their digest says it has bytes, as paths under the data directory.
        var brokenBlobs: [String] = []
        /// Blobs whose bytes do not hash to their digest (only with `verifyDigests`).
        var corruptBlobs: [String] = []

        /// Broken entries in all: what a repair deletes.
        var problems: Int { danglingLinks.count + brokenBlobs.count + corruptBlobs.count }
        var isHealthy: Bool { problems == 0 }
    }

    /// `registry:3`'s storage root inside the data directory.
    static func storageRoot(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("docker/registry/v2", isDirectory: true)
    }

    /// Checks every link and blob under `dataDirectory` without changing anything. A data directory the registry has
    /// not written yet is healthy and empty. `verifyDigests` also hashes each blob (slow on a big cache).
    static func scan(_ dataDirectory: URL, verifyDigests: Bool = false) -> Report {
        let root = storageRoot(in: canonical(dataDirectory))
        var report = Report()
        var bad = Set<String>()
        for blob in blobDirectories(under: root) {
            report.blobs += 1
            let data = blob.directory.appendingPathComponent("data")
            let size = fileSize(data)
            if size == nil || (size == 0 && blob.digest != emptyDigest) {
                report.brokenBlobs.append(relative(blob.directory, to: root))
                bad.insert(blob.digest)
            } else if verifyDigests, !digestMatches(data, blob.digest) {
                report.corruptBlobs.append(relative(blob.directory, to: root))
                bad.insert(blob.digest)
            }
        }
        for link in linkFiles(under: root.appendingPathComponent("repositories", isDirectory: true)) {
            report.links += 1
            guard let digest = linkedDigest(link) else {
                report.danglingLinks.append(relative(link, to: root))
                continue
            }
            let data = blobDirectory(for: digest, in: root).appendingPathComponent("data")
            if bad.contains(digest) || fileSize(data) == nil {
                report.danglingLinks.append(relative(link, to: root))
            }
        }
        report.danglingLinks.sort()
        report.brokenBlobs.sort()
        report.corruptBlobs.sort()
        return report
    }

    /// Deletes what `report` (a scan of `dataDirectory`) found broken, so the next pull fetches those layers and
    /// manifests from Docker Hub again: each dangling link's directory (`…/sha256/<digest>/`, or a tag's whole
    /// directory when its `current/link` dangles) and each broken blob's directory. Returns how many it deleted; one
    /// that is already gone counts, one that cannot be deleted is logged and skipped.
    @discardableResult
    static func repair(_ report: Report, in dataDirectory: URL) -> Int {
        let root = storageRoot(in: canonical(dataDirectory))
        var removed = 0
        let targets =
            (report.brokenBlobs + report.corruptBlobs).map { root.appendingPathComponent($0) }
            + report.danglingLinks.map { removalTarget(forLink: root.appendingPathComponent($0)) }
        for target in Set(targets).sorted(by: { $0.path < $1.path }) {
            do {
                try FileManager.default.removeItem(at: target)
                removed += 1
            } catch CocoaError.fileNoSuchFile {
                removed += 1
            } catch {
                Log.warn(
                    "container",
                    "Docker Hub cache: could not delete the broken entry \(target.path): \(error.localizedDescription)")
            }
        }
        return removed
    }

    /// What deleting a dangling link removes: a tag whose current manifest is gone loses its whole directory (the
    /// proxy then asks Docker Hub for the tag again); any other link loses its `<digest>/` directory.
    static func removalTarget(forLink link: URL) -> URL {
        let parent = link.deletingLastPathComponent()
        if parent.lastPathComponent == "current",
            parent.deletingLastPathComponent().deletingLastPathComponent()
                .lastPathComponent == "tags"
        {
            return parent.deletingLastPathComponent()
        }
        return parent
    }

    // MARK: - Walking the layout

    /// Every `blobs/sha256/<ab>/<digest>/` directory.
    private static func blobDirectories(under root: URL) -> [(digest: String, directory: URL)] {
        let shards = root.appendingPathComponent("blobs/sha256", isDirectory: true)
        return children(of: shards).flatMap { shard in
            children(of: shard).map { ($0.lastPathComponent, $0) }
        }
    }

    static func blobDirectory(for digest: String, in root: URL) -> URL {
        root.appendingPathComponent("blobs/sha256/\(digest.prefix(2))/\(digest)", isDirectory: true)
    }

    /// Every file named `link` under `directory` (the repositories' layer, manifest and tag links).
    private static func linkFiles(under directory: URL) -> [URL] {
        guard let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        var links: [URL] = []
        for case let url as URL in walk where url.lastPathComponent == "link" {
            // Not a regular file (or unreadable mid-walk): not a link the registry wrote, so it is left alone.
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            links.append(url)
        }
        return links
    }

    /// The hex digest a link file names (`sha256:<hex>`); nil when it names none.
    static func linkedDigest(_ link: URL) -> String? {
        // Unreadable: treated like a link that names nothing, which is what the registry would make of it too.
        guard let text = try? String(contentsOf: link, encoding: .utf8) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("sha256:") else { return nil }
        let hex = String(value.dropFirst("sha256:".count))
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex.lowercased()
    }

    private static func children(of directory: URL) -> [URL] {
        // A missing directory (nothing cached yet) has no children.
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private static func fileSize(_ url: URL) -> Int64? {
        // Missing or unreadable: the caller treats the blob as gone.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    private static func digestMatches(_ url: URL, _ digest: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }  // unreadable: not verifiable
        defer { try? handle.close() }  // a failed close of a read handle loses nothing
        var hasher = SHA256()
        do {
            // `read(upToCount:)` answers nil (or empty data) at the end of the file.
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        } catch {
            return false  // a read error mid-file: the bytes cannot be confirmed, so the blob counts as corrupt
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() == digest
    }

    /// `url`'s path under the storage root (`blobs/…`, `repositories/…`). Read from the layout's own marker rather
    /// than by prefix, since the file system may spell the same directory two ways (`/var` and `/private/var`).
    private static func relative(_ url: URL, to root: URL) -> String {
        let marker = "/docker/registry/v2/"
        guard let range = url.path.range(of: marker, options: .backwards) else { return url.path }
        return String(url.path[range.upperBound...])
    }

    /// `url` with every symlink resolved, the way the file system itself spells it (`realpath`): a data directory
    /// moved to another disk and left as a symlink is walked at its target. `url` unchanged when it does not exist.
    static func canonical(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
}
