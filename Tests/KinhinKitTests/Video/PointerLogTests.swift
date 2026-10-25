import CoreGraphics
import XCTest

@testable import KinhinKit

/// The pointer log `kinhin video record --pointer` writes: where the pointer was over the window and where it clicked. The
/// reading of the pointer itself needs a screen, so these tests feed it readings and check what comes out.
final class PointerLogTests: XCTestCase {
    private let window = CGRect(x: 100, y: 200, width: 800, height: 600)

    func testPointInsideTheWindowIsNormalised() throws {
        let point = try XCTUnwrap(PointerLogBuilder.normalized(CGPoint(x: 500, y: 350), in: window))
        XCTAssertEqual(point.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(point.y, 0.25, accuracy: 1e-9)
    }

    func testPointOutsideTheWindowIsNil() {
        XCTAssertNil(PointerLogBuilder.normalized(CGPoint(x: 50, y: 350), in: window))
        XCTAssertNil(PointerLogBuilder.normalized(CGPoint(x: 500, y: 900), in: window))
    }

    func testAnEmptyWindowHasNoPoints() {
        XCTAssertNil(PointerLogBuilder.normalized(.zero, in: .zero))
    }

    func testAPressIsOneClickHoldingTheButtonIsNot() {
        var builder = PointerLogBuilder(window: window)
        let at = CGPoint(x: 500, y: 350)
        builder.add(at: 10.0, point: at, leftDown: false)
        builder.add(at: 10.1, point: at, leftDown: true)  // the press
        builder.add(at: 10.2, point: at, leftDown: true)  // still held: not another click
        builder.add(at: 10.3, point: at, leftDown: false)
        builder.add(at: 10.4, point: at, leftDown: true)  // a second press
        let log = builder.finish(from: 10.0)
        XCTAssertEqual(log.clicks.map(\.t), [0.1, 0.4])
    }

    func testAClickOutsideTheWindowIsNotLogged() {
        var builder = PointerLogBuilder(window: window)
        builder.add(at: 1.0, point: CGPoint(x: 5, y: 5), leftDown: true)
        XCTAssertTrue(builder.finish(from: 0).clicks.isEmpty)
    }

    func testAHeldButtonAcrossTheEdgeStillCountsAsOnePressInside() {
        // Pressed outside, dragged in: the press is not a click on the window, and the drag is not a second one.
        var builder = PointerLogBuilder(window: window)
        builder.add(at: 1.0, point: CGPoint(x: 5, y: 5), leftDown: true)
        builder.add(at: 1.1, point: CGPoint(x: 500, y: 350), leftDown: true)
        XCTAssertTrue(builder.finish(from: 0).clicks.isEmpty)
    }

    func testReadingsBeforeTheFirstPictureAreDropped() {
        var builder = PointerLogBuilder(window: window)
        builder.add(at: 9.0, point: CGPoint(x: 500, y: 350), leftDown: true)
        builder.add(at: 10.5, point: CGPoint(x: 500, y: 350), leftDown: false)
        let log = builder.finish(from: 10.0)
        XCTAssertEqual(log.samples.map(\.t), [0.5])
        XCTAssertTrue(log.clicks.isEmpty)
    }

    func testTimesAreCountedFromTheFirstPictureToTheMillisecond() {
        var builder = PointerLogBuilder(window: window)
        builder.add(at: 10.0004, point: CGPoint(x: 500, y: 350), leftDown: false)
        builder.add(at: 12.3456, point: CGPoint(x: 600, y: 350), leftDown: true)
        let log = builder.finish(from: 10.0)
        XCTAssertEqual(log.samples.map(\.t), [0, 2.346])
        XCTAssertEqual(log.clicks, [PointerLog.Click(t: 2.346, x: 0.625, y: 0.25)])
    }

    func testOnlyInsideReadingsAreSampled() {
        var builder = PointerLogBuilder(window: window)
        builder.add(at: 1.0, point: CGPoint(x: 500, y: 350), leftDown: false)
        builder.add(at: 2.0, point: CGPoint(x: 5, y: 5), leftDown: false)
        XCTAssertEqual(builder.finish(from: 0).samples.count, 1)
    }

    func testTheLogWritesAndReadsBack() throws {
        let log = PointerLog(
            samples: [PointerLog.Sample(t: 0.5, x: 0.25, y: 0.75)],
            clicks: [PointerLog.Click(t: 1.2, x: 0.5, y: 0.5)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pointer-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try log.write(to: url)
        let back = try JSONDecoder().decode(PointerLog.self, from: Data(contentsOf: url))
        XCTAssertEqual(back, log)
        XCTAssertTrue(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("\"clicks\""))
    }
}
