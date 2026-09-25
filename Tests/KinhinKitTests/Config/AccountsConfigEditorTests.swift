import XCTest

@testable import KinhinKit

final class AccountsConfigEditorTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("kinhin-accounts-\(UUID().uuidString).yaml")
        try? """
        # my fleet
        repo: acme/widgets
        labels: [self-hosted]
        max_runners: 3   # keep small

        """.write(to: url, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func text() throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testAddAppendsAndPreservesTheRestOfTheFile() throws {
        try AccountsConfigEditor.add(AccountConfig(name: "work", forge: .github, scope: "bigco"), to: url)
        let updated = try text()
        XCTAssertTrue(updated.contains("# my fleet"))
        XCTAssertTrue(updated.contains("max_runners: 3   # keep small"))
        XCTAssertEqual(
            try AccountsConfigEditor.accounts(at: url), [AccountConfig(name: "work", forge: .github, scope: "bigco")])
    }

    func testAddSecondAccountKeepsTheFirst() throws {
        try AccountsConfigEditor.add(AccountConfig(name: "work", forge: .github, scope: "bigco"), to: url)
        try AccountsConfigEditor.add(
            AccountConfig(
                name: "home", forge: .gitea, scope: "me", instance: "https://git.lan", labels: ["macos:host"]),
            to: url)
        let accounts = try AccountsConfigEditor.accounts(at: url)
        XCTAssertEqual(accounts.map(\.name), ["work", "home"])
        XCTAssertEqual(accounts[1].labels, ["macos:host"])
        XCTAssertEqual(try text().components(separatedBy: "accounts:").count - 1, 1, "one accounts: block")
    }

    func testDuplicateNameIsRejectedAndNothingIsWritten() throws {
        try AccountsConfigEditor.add(AccountConfig(name: "work", forge: .github, scope: "bigco"), to: url)
        let before = try text()
        XCTAssertThrowsError(
            try AccountsConfigEditor.add(AccountConfig(name: "work", forge: .github, scope: "other"), to: url))
        XCTAssertEqual(try text(), before)
    }

    func testInvalidAccountIsRejectedAndNothingIsWritten() throws {
        let before = try text()
        XCTAssertThrowsError(
            try AccountsConfigEditor.add(AccountConfig(name: "home", forge: .gitea, scope: "me"), to: url)
        ) { error in
            guard case ConfigEditError.validation = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try text(), before)
    }

    func testUpdateReplacesInPlace() throws {
        try AccountsConfigEditor.add(AccountConfig(name: "work", forge: .github, scope: "bigco"), to: url)
        try AccountsConfigEditor.update(AccountConfig(name: "work", forge: .github, scope: "bigco/app"), at: url)
        XCTAssertEqual(try AccountsConfigEditor.accounts(at: url).first?.scope, "bigco/app")
        XCTAssertThrowsError(
            try AccountsConfigEditor.update(AccountConfig(name: "nope", forge: .github, scope: "x"), at: url))
    }

    func testRemoveDropsTheBlockWhenTheListEmpties() throws {
        try AccountsConfigEditor.add(AccountConfig(name: "work", forge: .github, scope: "bigco"), to: url)
        try AccountsConfigEditor.remove(name: "work", at: url)
        XCTAssertFalse(try text().contains("accounts:"))
        XCTAssertTrue(try text().contains("max_runners: 3"))
        XCTAssertThrowsError(try AccountsConfigEditor.remove(name: "work", at: url))
    }

    func testQuotesAndSpecialCharactersRoundTrip() throws {
        let odd = AccountConfig(
            name: "a", forge: .gitea, scope: "me/re\"po", instance: "https://git.lan", labels: ["a:b", "c d"])
        try AccountsConfigEditor.add(odd, to: url)
        XCTAssertEqual(try AccountsConfigEditor.accounts(at: url), [odd])
    }

    func testMissingFileThrowsNotFound() {
        let missing = url.appendingPathExtension("nope")
        XCTAssertThrowsError(try AccountsConfigEditor.accounts(at: missing)) { error in
            XCTAssertEqual(error as? ConfigEditError, .notFound(missing.path))
        }
    }
}
