import Foundation

/// What the two Ollama advisors share: one model on one server, the name the
/// journal shows for it, and the readiness check that gates it.
struct OllamaTier: Sendable {
    let client: OllamaClient
    let model: String
    /// The oldest Ollama version the model's endpoint works on.
    let minimumVersion: String

    init(host: URL, model: String, minimumVersion: String, session: URLSession) {
        self.client = OllamaClient(host: host, session: session)
        self.model = model
        self.minimumVersion = minimumVersion
    }

    var name: String { "ollama:\(model)" }

    func isAvailable() async -> Bool {
        await client.isReady(model: model, minimumVersion: minimumVersion)
    }
}
