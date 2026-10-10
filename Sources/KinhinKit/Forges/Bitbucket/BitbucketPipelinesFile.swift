import Foundation
import Synchronization
import Yams

// MARK: - bitbucket-pipelines.yml

/// The `runs-on` of each step a repository's `bitbucket-pipelines.yml` defines.
///
/// Bitbucket's public step payload carries no `runs_on`, so which steps this
/// fleet's runners could serve is read from the file at the pipeline's commit.
/// Steps are found wherever they sit (default, branches, pull-requests,
/// custom, parallel groups, stages, `definitions`): every mapping with a
/// `step` key whose value is a mapping.
struct BitbucketPipelinesFile: Sendable, Equatable {
    /// The file's name in the repository root.
    static let fileName = "bitbucket-pipelines.yml"

    /// Named steps' `runs-on` labels (empty for a cloud step).
    let namedSteps: [String: [String]]
    /// The `runs-on` labels of steps that carry no name.
    let unnamedSteps: [[String]]

    /// A commit with no pipeline file: every step is a cloud step.
    static let empty = BitbucketPipelinesFile(namedSteps: [:], unnamedSteps: [])

    init(namedSteps: [String: [String]], unnamedSteps: [[String]]) {
        self.namedSteps = namedSteps
        self.unnamedSteps = unnamedSteps
    }

    /// Parses `data`; throws the YAML error for an unparsable file.
    init(yaml data: Data) throws {
        let text = String(decoding: data, as: UTF8.self)
        var named: [String: [String]] = [:]
        var unnamed: [[String]] = []
        func visit(_ node: Any?) {
            if let map = node as? [AnyHashable: Any] {
                if let step = map["step"] as? [AnyHashable: Any] {
                    let labels = Self.runsOn(step["runs-on"])
                    if let name = step["name"] as? String {
                        // Duplicate names keep the self-hosted variant: an idle runner is cheaper than a stuck step.
                        if named[name] == nil || labels.contains(where: { $0.lowercased() == "self.hosted" }) {
                            named[name] = labels
                        }
                    } else {
                        unnamed.append(labels)
                    }
                }
                for value in map.values { visit(value) }
            } else if let list = node as? [Any] {
                for value in list { visit(value) }
            }
        }
        visit(try Yams.load(yaml: text))
        self.namedSteps = named
        self.unnamedSteps = unnamed
    }

    private static func runsOn(_ value: Any?) -> [String] {
        switch value {
        case let label as String: return [label]
        case let labels as [Any]: return labels.compactMap { $0 as? String }
        default: return []
        }
    }

    /// The `runs-on` labels of the step the API calls `name` (empty: a cloud
    /// step, or one the file does not define).
    func runsOn(stepNamed name: String?) -> [String] {
        if let name, let labels = namedSteps[name] { return labels }
        // An unnamed step is reported under a generated name: use one that is self-hosted when any is.
        return unnamedSteps.first { $0.contains { $0.lowercased() == "self.hosted" } } ?? []
    }
}

// MARK: - Per-commit cache

/// Parsed pipeline files by repository and commit. A commit's content never
/// changes, so an entry is valid forever; a commit without the file is
/// remembered as `BitbucketPipelinesFile.empty`. Bounded so a long-running
/// engine does not grow without limit.
final class BitbucketPipelinesFileCache: Sendable {
    private let entries = Mutex<[String: BitbucketPipelinesFile]>([:])
    private let limit: Int

    init(limit: Int = 128) { self.limit = limit }

    func lookup(_ key: String) -> BitbucketPipelinesFile? {
        entries.withLock { $0[key] }
    }

    func store(_ file: BitbucketPipelinesFile, for key: String) {
        entries.withLock { entries in
            if entries.count >= limit { entries.removeAll() }
            entries[key] = file
        }
    }
}
