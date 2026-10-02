import Foundation
import XCTest

@testable import KinhinKit

/// A throwaway project checkout under the temp directory.
final class ProjectFixture {
    let root: URL

    init(_ files: [String: String], file: StaticString = #filePath, line: UInt = #line) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-detect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, content) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }  // temp dir cleanup; failure is harmless

    var reader: ProjectFileReading { FileSystemProjectReader(root: root) }

    func detect() throws -> ToolchainDetection { try ProjectToolchainDetector().detect(at: root) }
}
