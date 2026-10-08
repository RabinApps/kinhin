import Foundation

extension KinhinConfig {
    /// One `projects:` entry: a repo pattern with its toolchain scope.
    public struct ProjectConfig: Sendable, Equatable {
        /// "owner/name", or "owner/*" for every repo of an owner.
        public var pattern: String
        /// Honor the repo's own `.kinhin.yml` (read at the job's ref). Off by
        /// default: a repo file chooses what is installed on this Mac.
        public var repoFile: Bool
        /// This project's own toolchains: used when the repo has no usable
        /// `.kinhin.yml` (or `repo_file` is off). nil = nothing baked.
        public var toolchains: ToolchainsConfig?
        /// Mount the host toolchain cache while baking and running this
        /// project's images (nil = off for projects: isolation by default).
        public var shareCache: Bool?

        public init(
            pattern: String, repoFile: Bool = false, toolchains: ToolchainsConfig? = nil, shareCache: Bool? = nil
        ) {
            self.pattern = pattern
            self.repoFile = repoFile
            self.toolchains = toolchains
            self.shareCache = shareCache
        }

        enum CodingKeys: String, CodingKey {
            case pattern
            case repoFile = "repo_file"
            case toolchains
            case shareCache = "share_cache"
        }

        /// True when this entry covers `repository` ("owner/name").
        public func matches(_ repository: String) -> Bool {
            let key = repository.lowercased()
            let want = pattern.lowercased()
            if want.hasSuffix("/*") { return key.hasPrefix(String(want.dropLast())) }
            return key == want
        }
    }
}
