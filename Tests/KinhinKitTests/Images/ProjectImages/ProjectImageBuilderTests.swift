import Synchronization
import XCTest

@testable import KinhinKit
@testable import KinhinTestSupport

final class ProjectImageBuilderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-pib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)  // test temp dir
    }

    private func toolchains(_ spec: String) -> KinhinConfig.ToolchainsConfig {
        var value = KinhinConfig.ToolchainsConfig()
        value.specs = [spec]
        return value
    }

    func testMissingImageStartsOneBakeThenIsReady() async {
        let tart = FakeTart()
        struct Baked: Sendable {
            let source: String
            let target: String
            let provision: String?
            let shareCache: Bool
        }
        let bakes = Locked<[Baked]>([])
        let builder = ProjectImageBuilder(
            tart: tart, store: ProjectImageStore(directory: dir), baseImage: "tahoe-base",
            bake: { options in
                let baked = Baked(
                    source: options.source, target: options.target, provision: options.provisionScriptPath,
                    shareCache: options.shareCache)
                bakes.withLock { $0.append(baked) }
                tart.vms[options.target] = TartVM(name: options.target, source: "local", status: "stopped")
            })
        let first = await builder.request(toolchains: toolchains("go@1.22.5"), shareCache: false)
        let again = await builder.request(toolchains: toolchains("go@1.22.5"), shareCache: false)
        guard case .building(let name) = first else { return XCTFail("expected building, got \(first)") }
        XCTAssertEqual(again, .building(name: name))
        await builder.waitForBakes()
        let ready = await builder.request(toolchains: toolchains("go@1.22.5"), shareCache: false)
        XCTAssertEqual(ready, .ready(name: name))
        let recorded = bakes.withLock { $0 }
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.source, "tahoe-base")
        XCTAssertEqual(recorded.first?.target, name)
        XCTAssertNil(recorded.first?.provision)
        XCTAssertFalse(recorded.first?.shareCache ?? true)
    }

    func testFailedBakeIsNotRetriedImmediately() async {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let clock = Locked(Date(timeIntervalSince1970: 0))
        let count = Locked(0)
        let builder = ProjectImageBuilder(
            tart: FakeTart(), store: ProjectImageStore(directory: dir), baseImage: "tahoe-base",
            bake: { _ in
                count.withLock { $0 += 1 }
                throw Boom()
            }, now: { clock.withLock { $0 } })
        _ = await builder.request(toolchains: toolchains("go@1.22.5"), shareCache: false)
        await builder.waitForBakes()
        let result = await builder.request(toolchains: toolchains("go@1.22.5"), shareCache: false)
        guard case .failed(_, let reason) = result else { return XCTFail("expected failed, got \(result)") }
        XCTAssertEqual(reason, "boom")
        XCTAssertEqual(count.withLock { $0 }, 1)
        clock.withLock { $0 = Date(timeIntervalSince1970: ProjectImageBuilder.retryAfter) }
        _ = await builder.request(toolchains: toolchains("go@1.22.5"), shareCache: false)
        await builder.waitForBakes()
        XCTAssertEqual(count.withLock { $0 }, 2)
    }

    func testPruneDeletesLRUAndKeepsInUse() async {
        let tart = FakeTart()
        let store = ProjectImageStore(directory: dir)
        for (i, name) in ["a", "b", "c"].enumerated() {
            store.upsert(
                ProjectImageRecord(
                    name: name, key: name, base: "x", summary: "", createdAt: Date(timeIntervalSince1970: Double(i)),
                    lastUsedAt: Date(timeIntervalSince1970: Double(i)),
                    toolchains: .init(KinhinConfig.ToolchainsConfig()), shareCache: false))
            tart.vms[name] = TartVM(name: name, source: "local", status: "stopped")
        }
        let builder = ProjectImageBuilder(tart: tart, store: store, baseImage: "x", bake: { _ in })
        let removed = await builder.prune(maxImages: 1, maxAgeDays: 0, inUse: ["a"])
        XCTAssertEqual(removed.sorted(), ["b", "c"])
        XCTAssertEqual(Set(store.all.map(\.name)), ["a"])
    }
}
