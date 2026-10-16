import Foundation

extension KinhinConfig {
    /// The healing agent (`healing:`): which problems it may fix on its own
    /// and whether the on-device model is asked about the ones no rule covers.
    public struct HealingConfig: Sendable, Equatable {
        /// What runs without asking.
        public enum AutoMode: String, Sendable, CaseIterable {
            /// Safe, reversible fixes run on their own; the rest wait for approval.
            case safe
            /// Every fix waits for approval.
            case none
        }

        /// Whether the on-device model advises on problems no rule covers.
        public enum AIMode: String, Sendable, CaseIterable {
            /// On when this Mac has Apple Intelligence (macOS 26+).
            case auto
            case off
        }

        /// Off: no signals, no journal, no fixes (the engine's own retries still run).
        public var enabled: Bool
        public var auto: AutoMode
        public var ai: AIMode
        /// Tries of one fix for one problem before it escalates.
        public var maxAttempts: Int

        public init(enabled: Bool = true, auto: AutoMode = .safe, ai: AIMode = .auto, maxAttempts: Int = 3) {
            self.enabled = enabled
            self.auto = auto
            self.ai = ai
            self.maxAttempts = maxAttempts
        }

        public static let `default` = HealingConfig()

        /// The allowed range of `max_attempts`.
        static let maxAttemptsRange = 1...10

        enum CodingKeys: String, CodingKey {
            case enabled, auto, ai
            case maxAttempts = "max_attempts"
        }
    }
}
