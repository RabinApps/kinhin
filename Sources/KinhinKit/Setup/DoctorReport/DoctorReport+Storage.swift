import Foundation

extension DoctorReport {
    /// The configured storage paths (`tart_home:`, `container_app_root:`, `registry_cache_path:`,
    /// `toolchain_cache_path:`) and the preflight the daemon runs before it starts: each volume mounted, with
    /// ownership enabled. Present only when at least one path is configured. A failed path makes `ready` false: the
    /// daemon will not start until it is fixed.
    public struct StorageSection: Codable, Equatable, Sendable {
        /// One configured path.
        public struct Path: Codable, Equatable, Sendable {
            /// The config key (`tart_home`, `container_app_root`, `registry_cache_path`, `toolchain_cache_path`).
            public let key: String
            public let path: String
            /// The volume holding it, when it could be read.
            public let mountPoint: String?
            public let ok: Bool
            /// What is wrong, null when ok.
            public let problem: String?
            /// What to do about it, null when ok.
            public let fix: String?

            public init(key: String, path: String, mountPoint: String?, ok: Bool, problem: String?, fix: String?) {
                self.key = key
                self.path = path
                self.mountPoint = mountPoint
                self.ok = ok
                self.problem = problem
                self.fix = fix
            }
        }

        public let paths: [Path]
        /// Whether every configured path passed the preflight.
        public let ok: Bool

        public init(paths: [Path]) {
            self.paths = paths
            self.ok = paths.allSatisfy(\.ok)
        }
    }
}

// MARK: - Building the section

extension DoctorReportBuilder {
    /// The storage section for `config`; nil when the config did not parse or configures no storage path.
    static func storageSection(config: KinhinConfig?, preflight: StoragePreflight) -> DoctorReport.StorageSection? {
        guard let storage = config?.storage, !storage.isEmpty else { return nil }
        let paths = preflight.check(storage).map { outcome in
            DoctorReport.StorageSection.Path(
                key: outcome.location.configKey, path: outcome.path, mountPoint: outcome.mountPoint, ok: outcome.ok,
                problem: outcome.problem?.problem, fix: outcome.problem?.fix)
        }
        return DoctorReport.StorageSection(paths: paths)
    }
}
