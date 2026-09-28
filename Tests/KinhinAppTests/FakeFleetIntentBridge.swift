@testable import KinhinKit
@testable import kinhin_app

/// Shared fake for the App Intent tests: records what the intents dispatch
/// and can apply status changes like the real backend would.
@MainActor
final class FakeFleetIntentBridge: FleetIntentBridge {
    var current: FleetStatus
    var error: Error?
    /// Fails only `setPaused`, modeling a backend that rejects the pause
    /// while status and other commands still work.
    var pauseError: Error?
    private(set) var setPausedCalls: [Bool] = []
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var deleteCalls: [String] = []
    /// Current auto-resume policy the fake reports; mutations are recorded.
    var autoResume = false
    private(set) var autoResumeCalls: [Bool] = []
    /// When set, start/stop flips `running` like the real backend would.
    var appliesStartStop = false
    /// When set, delete removes the record like the real backend would.
    var appliesDelete = false

    init(_ status: FleetStatus) { current = status }

    func status() async throws -> FleetStatus {
        if let error { throw error }
        return current
    }

    func startFleet() async throws {
        if let error { throw error }
        startCalls += 1
        if appliesStartStop { current.running = true }
    }

    func stopFleet() async throws {
        if let error { throw error }
        stopCalls += 1
        if appliesStartStop { current.running = false }
    }

    func setPaused(_ paused: Bool) async throws {
        if let error { throw error }
        if let pauseError { throw pauseError }
        setPausedCalls.append(paused)
        current.paused = paused
    }

    func deleteVM(id: String) async throws {
        if let error { throw error }
        deleteCalls.append(id)
        if appliesDelete { current.records.removeAll { $0.id == id } }
    }

    func autoResumeEnabled() async throws -> Bool {
        if let error { throw error }
        return autoResume
    }

    func setAutoResume(_ on: Bool) async throws {
        if let error { throw error }
        autoResumeCalls.append(on)
        autoResume = on
    }

    func doctor() async -> DoctorReport { fatalError("not used") }
}
