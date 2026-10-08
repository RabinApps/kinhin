import XCTest

@testable import KinhinKit

final class ExpressionEvaluatorTests: XCTestCase {
    private let evaluator = ExpressionEvaluator(root: URL(fileURLWithPath: "/repo"))

    // MARK: - expand

    func testExpandsWorkspaceRunnerAndEnvExpressions() {
        var notices: [String] = []
        let out = evaluator.expand(
            "cd ${{ github.workspace }} && echo ${{ runner.os }}/${{ runner.arch }} ${{ env.GREETING }}",
            env: ["GREETING": "hi"], notices: &notices)
        XCTAssertEqual(out, "cd /repo && echo macOS/arm64 hi")
        XCTAssertEqual(notices, [])
    }

    func testMissingEnvExpandsToEmptyString() {
        var notices: [String] = []
        XCTAssertEqual(evaluator.expand("[${{ env.NOPE }}]", env: [:], notices: &notices), "[]")
    }

    func testSecretsExpandEmptyWithOneNoticePerSecret() {
        var notices: [String] = []
        let out = evaluator.expand(
            "a=${{ secrets.TOKEN }} b=${{ secrets.TOKEN }} c=${{secrets.OTHER}}", env: [:], notices: &notices)
        XCTAssertEqual(out, "a= b= c=")
        XCTAssertEqual(
            notices,
            [
                "secrets are unavailable locally; OTHER expanded to an empty string",
                "secrets are unavailable locally; TOKEN expanded to an empty string",
            ])
    }

    func testUnknownExpressionIsLeftLiteralWithANotice() {
        var notices: [String] = []
        let out = evaluator.expand("echo ${{ github.sha }}", env: [:], notices: &notices)
        XCTAssertEqual(out, "echo ${{ github.sha }}")
        XCTAssertEqual(notices, ["unknown expression left literal"])
    }

    // MARK: - evaluate

    func testNoConditionAlwaysRuns() {
        XCTAssertEqual(
            evaluator.evaluate(condition: nil, previousFailure: true),
            .init(shouldRun: true, forceRun: false, notice: nil))
    }

    func testSupportedConditionsHonourPreviousFailure() {
        func run(_ raw: String, failed: Bool) -> (Bool, Bool) {
            let c = evaluator.evaluate(condition: raw, previousFailure: failed)
            return (c.shouldRun, c.forceRun)
        }
        XCTAssertTrue(run("true", failed: true).0)
        XCTAssertFalse(run("false", failed: false).0)
        XCTAssertTrue(run("success()", failed: false).0)
        XCTAssertFalse(run("success()", failed: true).0)
        XCTAssertEqual(run("always()", failed: true).0, true)
        XCTAssertEqual(run("always()", failed: true).1, true)
        XCTAssertFalse(run("failure()", failed: false).0)
        XCTAssertTrue(run("failure()", failed: true).0)
        XCTAssertFalse(run("cancelled()", failed: true).0)
    }

    func testConditionsMayBeWrappedAndAreCaseInsensitive() {
        XCTAssertTrue(evaluator.evaluate(condition: "${{ Always() }}", previousFailure: true).forceRun)
        XCTAssertTrue(evaluator.evaluate(condition: "${{success()}}", previousFailure: false).shouldRun)
    }

    func testUnsupportedConditionIsSkippedWithANotice() {
        let c = evaluator.evaluate(condition: "github.ref == 'refs/heads/main'", previousFailure: false)
        XCTAssertFalse(c.shouldRun)
        XCTAssertEqual(c.notice, "unsupported condition 'github.ref == 'refs/heads/main'' skipped")
    }
}
