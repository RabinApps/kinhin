import XCTest

@testable import KinhinKit

final class LaunchAgentEscapingTests: XCTestCase {
    func testXMLSpecialCharactersAreEscaped() {
        XCTAssertEqual(
            Daemon.xmlEscaped("/Applications/R&D <tools>/kinhin"), "/Applications/R&amp;D &lt;tools&gt;/kinhin")
        XCTAssertEqual(Daemon.xmlEscaped(#"a"b'c"#), "a&quot;b&apos;c")
        XCTAssertEqual(Daemon.xmlEscaped("&amp;"), "&amp;amp;", "escaping is not idempotent: input is raw text")
        XCTAssertEqual(Daemon.xmlEscaped("/plain/path"), "/plain/path")
    }

    func testEscapedPathsStayWellFormedXML() throws {
        let path = "/Users/me/R&D <x>/kinhin"
        let xml = "<plist><dict><string>\(Daemon.xmlEscaped(path))</string></dict></plist>"
        let doc = try XMLDocument(xmlString: xml)
        XCTAssertEqual(try doc.nodes(forXPath: "//string").first?.stringValue, path)
    }
}
