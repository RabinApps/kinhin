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
