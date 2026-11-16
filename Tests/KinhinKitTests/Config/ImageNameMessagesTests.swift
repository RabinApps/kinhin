import XCTest

@testable import KinhinKit

/// #107: a duplicate image name says which key already has it and how to fix it, and a config that leaves `image:`
/// out is told the default it gets (`ConfigLoader.notes`) instead of getting `tahoe-base` silently.
final class ImageNameMessagesTests: XCTestCase {
    private static let head = """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        labels: [self-hosted]

        """

    private func message(_ yaml: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            _ = try ConfigLoader.parse(Self.head + yaml)
            XCTFail("expected a ConfigError for:\n\(yaml)", file: file, line: line)
            return ""
        } catch ConfigError.invalid(let why) {
            return why
        } catch {
            XCTFail("expected ConfigError.invalid, got \(error)", file: file, line: line)
            return ""
        }
    }

    // MARK: - Duplicate names

    func testAClashWithTheDefaultImageSaysItIsTheDefault() {
        // image: left out, so it is tahoe-base, a name the file never spells.
        let why = message("images:\n  - name: tahoe-base\n    labels: [xcode]\n")
        XCTAssertTrue(why.contains("images[0].name 'tahoe-base'"), why)
        XCTAssertTrue(why.contains("image:, which is not set and so defaults to 'tahoe-base'"), why)
        XCTAssertTrue(why.contains("Rename this images: entry, or set image:"), "names the fix: \(why)")
    }

    func testAClashWithASetImageNamesBothKeys() {
        let why = message("image: sequoia\nimages:\n  - name: sequoia\n    labels: [xcode]\n")
        XCTAssertTrue(why.contains("images[0].name 'sequoia' is the same as image: 'sequoia'"), why)
        XCTAssertTrue(why.contains("rename this images: entry, or change image:"), why)
        XCTAssertFalse(why.contains("defaults to"), why)
    }

    func testAClashBetweenTwoEntriesNamesTheEarlierOne() {
        let why = message(
            "images:\n  - name: xcode\n    labels: [xcode]\n  - name: plain\n  - name: xcode\n    labels: [x2]\n")
        XCTAssertTrue(why.contains("images[2].name 'xcode' is already used by images[0].name"), why)
        XCTAssertTrue(why.contains("rename one of them"), why)
    }

    func testTheMessageHelperCoversEachCase() {
        let earlier = ConfigLoader.duplicateImageNameMessage(name: "a", index: 3, earlier: 1, primaryIsDefault: true)
        XCTAssertTrue(earlier.hasPrefix("images[3].name 'a' is already used by images[1].name"), earlier)
        let primary = ConfigLoader.duplicateImageNameMessage(name: "a", index: 0, earlier: nil, primaryIsDefault: false)
        XCTAssertTrue(primary.contains("is the same as image: 'a'"), primary)
    }

    // MARK: - The default image: note

    func testLeavingImageOutIsNoted() {
        let notes = ConfigLoader.notes(forYAML: Self.head)
        XCTAssertEqual(notes, [ConfigLoader.defaultImageNote])
        XCTAssertTrue(notes[0].contains("'tahoe-base'"), notes[0])
        XCTAssertTrue(notes[0].contains("set image:"), notes[0])
    }

    func testASetImageHasNoNote() {
        XCTAssertEqual(ConfigLoader.notes(forYAML: Self.head + "image: tahoe-base\n"), [])
    }

    func testAnUndecodableFileHasNoNotes() {
        XCTAssertEqual(ConfigLoader.notes(forYAML: "image: [unclosed"), [])
    }

    func testNotesAtAPathReadTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.yaml")
        try Self.head.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ConfigLoader.notes(at: url).count, 1)
        XCTAssertEqual(ConfigLoader.notes(at: dir.appendingPathComponent("missing.yaml")), [])
    }
}
