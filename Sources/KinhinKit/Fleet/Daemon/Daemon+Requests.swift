import Foundation

extension Daemon {
    /// Payload of `pipeline_log`: a job of the VM's pipeline and, optionally,
    /// the position of one of its steps.
    public struct PipelineLogRequest: Codable {
        public let id: String
        public let jobID: String
        public let stepIndex: Int?
        public init(id: String, jobID: String, stepIndex: Int?) {
            self.id = id
            self.jobID = jobID
            self.stepIndex = stepIndex
        }
    }

    /// Optional payload of `status`. Absent, `status` samples usage as it
    /// always did, so older clients and daemons stay compatible.
    public struct StatusRequest: Codable {
        public let includeUsage: Bool
        public init(includeUsage: Bool) { self.includeUsage = includeUsage }
    }

    public struct VMDeleteRequest: Codable {
        public let id: String
        public init(id: String) { self.id = id }
    }

    public struct ForgeJobsRequest: Codable, Sendable {
        public let forge: ForgeID
        public init(forge: ForgeID) { self.forge = forge }
    }
}
