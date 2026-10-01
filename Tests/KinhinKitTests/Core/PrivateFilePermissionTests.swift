import XCTest

@testable import KinhinKit

/// Logs and fleet state are owner-only: they hold VM ids, addresses and
/// repository names.
final class PrivateFilePermissionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kn-perm-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func mode(_ url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        return try XCTUnwrap(value) & 0o777
    }

    func testPrivateDirectoryIsOwnerOnly() throws {
        let nested = root.appendingPathComponent("logs")
        try Paths.createPrivateDirectory(nested)
        XCTAssertEqual(try mode(nested), 0o700)
    }

    func testLogFileIsCreatedOwnerOnly() throws {
        try Paths.createPrivateDirectory(root)
        let file = root.appendingPathComponent("kinhin.log")
        let log = try RotatingLogFile(url: file)
        try log.append(Data("line\n".utf8))
        XCTAssertEqual(try mode(file), 0o600)
    }

    func testFleetStateFileIsOwnerOnlyAfterPersisting() throws {
        try Paths.createPrivateDirectory(root)
        let store = FleetStore(directory: root)
        store.upsert(VMRecord(id: "kinhin-1", phase: .ready))
        XCTAssertEqual(try mode(root.appendingPathComponent("fleet.json")), 0o600)
    }

    func testExistingWorldReadableLogIsTightenedOnOpen() throws {
        try Paths.createPrivateDirectory(root)
        let file = root.appendingPathComponent("kinhin.log")
        XCTAssertTrue(
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o644]))
        _ = try RotatingLogFile(url: file)
        XCTAssertEqual(try mode(file), 0o600)
    }
}
