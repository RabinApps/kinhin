import XCTest

@testable import KinhinKit

final class RPCCodecTests: XCTestCase {
    func testRPCRoundTrip() throws {
        let request = RPCRequest(id: 42, method: .status)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(RPCRequest.self, from: data)
        XCTAssertEqual(decoded, request)

        let response = RPCResponse(id: 42, ok: true, payload: Data("hi".utf8))
        let rdata = try JSONEncoder().encode(response)
        let rdecoded = try JSONDecoder().decode(RPCResponse.self, from: rdata)
        XCTAssertEqual(rdecoded, response)
    }
}

final class RPCCommandTests: XCTestCase {
    func testRejectedResponseThrowsWithTheDaemonsReason() {
        let response = RPCResponse(id: 1, ok: false, error: "no engine")
        XCTAssertThrowsError(try RPCClient.requireOK(response)) { error in
            guard case RPCError.rejected(let why) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(why, "no engine")
        }
    }

    func testOKResponsePassesThrough() throws {
        let response = RPCResponse(id: 1, ok: true)
        XCTAssertTrue(try RPCClient.requireOK(response).ok)
    }

    func testCommandThrowsWhenNoDaemonIsListening() {
        let client = RPCClient(socketURL: FileManager.default.temporaryDirectory.appendingPathComponent("nope.sock"))
        XCTAssertThrowsError(try client.command(.start)) { error in
            guard case RPCError.connectionFailed = error else { return XCTFail("wrong error: \(error)") }
        }
    }
}
