import XCTest

@testable import KinhinKit

/// Which steps of a `bitbucket-pipelines.yml` ask for a self-hosted runner. The step payload of the API carries no
/// `runs_on`, so this is what separates this fleet's demand from cloud steps.
final class BitbucketPipelinesFileTests: XCTestCase {
    func testStepsAreFoundInEveryPipelineSection() throws {
        let file = try BitbucketPipelinesFile(
            yaml: Data(
                """
                image: atlassian/default-image:4
                definitions:
                  steps:
                    - step: &build
                        name: Build
                        runs-on:
                          - self.hosted
                          - linux.shell
                        script: [make]
                pipelines:
                  default:
                    - step: *build
                    - parallel:
                        steps:
                          - step:
                              name: Lint
                              runs-on: self.hosted
                              script: [make lint]
                          - step:
                              name: Docs
                              script: [make docs]
                    - stage:
                        name: Release
                        steps:
                          - step:
                              name: Publish
                              runs-on: [self.hosted, macos]
                              script: [make publish]
                  branches:
                    main:
                      - step:
                          name: Smoke
                          script: [make smoke]
                  pull-requests:
                    '**':
                      - step:
                          script: [make pr]
                """.utf8))
        XCTAssertEqual(file.runsOn(stepNamed: "Build"), ["self.hosted", "linux.shell"])
        XCTAssertEqual(file.runsOn(stepNamed: "Lint"), ["self.hosted"])
        XCTAssertEqual(file.runsOn(stepNamed: "Publish"), ["self.hosted", "macos"])
        XCTAssertEqual(file.runsOn(stepNamed: "Docs"), [], "a step without runs-on runs on Bitbucket's cloud")
        XCTAssertEqual(file.runsOn(stepNamed: "Smoke"), [])
        XCTAssertEqual(file.runsOn(stepNamed: "Nope"), [], "the unnamed step is a cloud step")
    }

    func testAnUnnamedSelfHostedStepAnswersForNamesTheFileDoesNotHave() throws {
        let file = try BitbucketPipelinesFile(
            yaml: Data(
                """
                pipelines:
                  default:
                    - step:
                        runs-on: self.hosted
                        script: [make]
                """.utf8))
        XCTAssertEqual(file.runsOn(stepNamed: "Build and Test"), ["self.hosted"])
    }

    func testAnUnparsableFileThrows() {
        XCTAssertThrowsError(try BitbucketPipelinesFile(yaml: Data("pipelines: [unclosed".utf8)))
    }

    func testCacheRemembersAFilePerCommit() {
        let cache = BitbucketPipelinesFileCache(limit: 2)
        XCTAssertNil(cache.lookup("acme/api@abc"))
        cache.store(.empty, for: "acme/api@abc")
        XCTAssertEqual(cache.lookup("acme/api@abc"), .empty)
        cache.store(.empty, for: "acme/api@def")
        cache.store(.empty, for: "acme/api@ghi")
        XCTAssertNil(cache.lookup("acme/api@abc"), "the cache is bounded")
        XCTAssertNotNil(cache.lookup("acme/api@ghi"))
    }
}
