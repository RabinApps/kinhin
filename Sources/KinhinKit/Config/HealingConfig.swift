import Foundation

extension KinhinConfig {
    /// The healing agent (`healing:`): which problems it may fix on its own
    /// and which advisor is asked about the ones no rule covers.
    public struct HealingConfig: Sendable, Equatable {
        /// What runs without asking.
        public enum AutoMode: String, Sendable, CaseIterable {
            /// Safe, reversible fixes run on their own; the rest wait for approval.
            case safe
            /// Every fix waits for approval.
            case none
        }

        /// Which advisor is asked about problems no rule covers.
        public enum AIMode: String, Sendable, CaseIterable {
            /// On when this Mac has Apple Intelligence (macOS 26+).
            case auto
            case off
            /// Ollama (`healing.ollama`): a decision model first, then the LLM.
            case ollama
        }

        /// The Ollama models for `ai: ollama`.
        public struct OllamaConfig: Sendable, Equatable {
            /// The Ollama server. Loopback by default; any other host must be https.
            public var host: URL
            /// The LLM, asked when the fast model is unsure or picks nothing.
            public var model: String
            /// The System 1 decision model, asked first. Nil: the LLM alone.
            public var fastModel: String?

            public init(host: URL = OllamaConfig.defaultHost, model: String, fastModel: String? = nil) {
                self.host = host
                self.model = model
                self.fastModel = fastModel
            }

            /// Ollama's default address on this Mac.
            public static let defaultHost: URL = {
                guard let url = URL(string: "http://127.0.0.1:11434") else {
                    preconditionFailure("the default Ollama host is a valid URL")
                }
                return url
            }()

            /// Whether `url` names this Mac (localhost, 127.0.0.1 or ::1).
            public static func isLoopback(_ url: URL) -> Bool {
                let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
                return ["localhost", "127.0.0.1", "::1"].contains(host ?? "")
            }
        }

        /// Off: no signals, no journal, no fixes (the engine's own retries still run).
        public var enabled: Bool
        public var auto: AutoMode
        public var ai: AIMode
        /// Tries of one fix for one problem before it escalates.
        public var maxAttempts: Int
        /// The Ollama models, set when `ai` is `.ollama`.
        public var ollama: OllamaConfig?

        public init(
            enabled: Bool = true, auto: AutoMode = .safe, ai: AIMode = .auto, maxAttempts: Int = 3,
            ollama: OllamaConfig? = nil
        ) {
            self.enabled = enabled
            self.auto = auto
            self.ai = ai
            self.maxAttempts = maxAttempts
            self.ollama = ollama
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
