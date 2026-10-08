import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

/// A replaced engine must be freed. The engine owns its scale-set listeners,
/// and the listeners keep closures that call back into the engine, so a
/// strong capture is a cycle that keeps every replaced engine (and its
/// forges, runtimes and caches) alive for the life of the daemon.
final class EngineDeallocationTests: XCTestCase {
    let host = HostResources(logicalCores: 12, memoryGB: 32, freeDiskGB: 200, arm64: true)

    private func scaleSetConfig() -> KinhinConfig {
        var cfg = makeTestConfig()
        cfg.accounts = [
            AccountConfig(name: "scale", forge: .github, scope: "acme/widgets", scaleSet: .init(name: "kinhin"))
        ]
        return cfg
    }

    private func makeEngine(_ config: KinhinConfig) -> FleetEngine {
        FleetEngine(
            config: config, github: FakeGitHub(), tart: FakeTart(), store: makeTestStore(), ssh: FakeSSH(),
            host: host, dependencies: .init(tokenLoader: { _, _ in "t" }, exitWatchInterval: .milliseconds(20)))
    }

    /// Builds, attaches (listeners created, their closures live) and detaches an engine, handing back only
    /// weak references so nothing here keeps it alive.
    private func attachedAndDetached() async -> (
        engine: WeakBox<FleetEngine>, listener: WeakBox<GitHubScaleSetListener>
    ) {
        let config = scaleSetConfig()
        let engine = makeEngine(config)
        _ = await engine.attach(account: config.accounts[0], token: "t", verify: false)
        let listener = engine.scaleSetListeners()["scale"]?.first
        XCTAssertNotNil(listener, "the scale-set account attached with a listener")
        // The listener's closures are what could pin the engine: exercise them once.
        _ = try? await listener?.currentScaleSetId()
        await engine.detachKeepingInstances()
        return (WeakBox(engine), WeakBox(listener))
    }

    func testDetachedEngineWithScaleSetListenerDeallocates() async {
        let (engine, listener) = await attachedAndDetached()
        // Tasks that were cancelled by the detach release their captures on their next turn.
        await waitForCondition(timeout: 5) { engine.value == nil }
        XCTAssertNil(engine.value, "a detached engine must not be kept alive by its own listener's closures")
        XCTAssertNil(listener.value, "and its listener goes with it")
    }

    func testStartedThenStoppedEngineDeallocates() async {
        let box: WeakBox<FleetEngine> = await {
            let config = makeTestConfig()
            let engine = makeEngine(config)
            await engine.start()
            await engine.stop()
            return WeakBox(engine)
        }()
        await waitForCondition(timeout: 5) { box.value == nil }
        XCTAssertNil(box.value)
    }
}

private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T?) { self.value = value }
}
