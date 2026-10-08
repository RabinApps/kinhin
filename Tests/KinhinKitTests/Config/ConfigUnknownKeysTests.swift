import XCTest

@testable import KinhinKit

/// Yams ignores keys the typed decode does not know, so the loader checks the
/// document against `ConfigSchema` itself: a typo is an error with a
/// suggestion, a newer `version:` relaxes that.
final class ConfigUnknownKeysTests: XCTestCase {
    private static let account = """
        accounts:
          - name: github
            forge: github
            scope: "acme/widgets"
        """

    private func invalidMessage(_ yaml: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            _ = try ConfigLoader.parse(yaml)
            XCTFail("expected a ConfigError", file: file, line: line)
            return ""
        } catch ConfigError.invalid(let why) {
            return why
        } catch {
            XCTFail("expected ConfigError.invalid, got \(error)", file: file, line: line)
            return ""
        }
    }

    // MARK: - Unknown keys are errors with suggestions

    func testTopLevelTypoSuggestsTheRealKey() {
        let why = invalidMessage("\(Self.account)\nmax_runner: 4\n")
        XCTAssertTrue(why.contains("unknown key 'max_runner'"), why)
        XCTAssertTrue(why.contains("did you mean 'max_runners'?"), why)
    }

    func testCaseAndSeparatorVariantsAreSuggested() {
        XCTAssertTrue(invalidMessage("\(Self.account)\nmax-runners: 4\n").contains("did you mean 'max_runners'?"))
        XCTAssertTrue(invalidMessage("\(Self.account)\nrunnersPerVM: 2\n").contains("did you mean 'runners_per_vm'?"))
    }

    func testNestedTypoNamesThePath() {
        let why = invalidMessage("\(Self.account)\nvm:\n  cpus: 4\n")
        XCTAssertTrue(why.contains("unknown key 'vm.cpus'"), why)
        XCTAssertTrue(why.contains("did you mean 'vm.cpu'?"), why)
    }

    func testListItemsAreCheckedWithTheirIndex() {
        let yaml = """
            accounts:
              - name: github
                forge: github
                scope: "acme/widgets"
              - name: work
                forge: gitlab
                scop: "group/project"
            """
        let why = invalidMessage(yaml)
        XCTAssertTrue(why.contains("unknown key 'accounts[1].scop'"), why)
        XCTAssertTrue(why.contains("did you mean 'accounts[1].scope'?"), why)
    }

    func testRoutesScaleSetAndProjectToolchainsAreChecked() {
        let routes = invalidMessage(
            """
            \(Self.account)
            runtimes:
              routes:
                - pattern: acme/widgets
                  runtime: tart
                  concent: true
            """)
        XCTAssertTrue(routes.contains("did you mean 'runtimes.routes[0].consent'?"), routes)

        let scaleSet = invalidMessage(
            """
            accounts:
              - name: github
                forge: github
                scope: acme/widgets
                scale_set:
                  name: kinhin
                  runner_grup: mine
            """)
        XCTAssertTrue(scaleSet.contains("did you mean 'accounts[0].scale_set.runner_group'?"), scaleSet)

        let projects = invalidMessage(
            """
            \(Self.account)
            projects:
              - pattern: acme/widgets
                toolchains:
                  spec: [go@1.23.4]
            """)
        XCTAssertTrue(projects.contains("did you mean 'projects[0].toolchains.specs'?"), projects)
    }

    func testEveryUnknownKeyIsReportedAtOnce() {
        let why = invalidMessage("\(Self.account)\nmax_runner: 4\nlabelz: [a]\n")
        XCTAssertTrue(why.contains("'max_runner'"), why)
        XCTAssertTrue(why.contains("'labelz'"), why)
    }

    func testNoSuggestionWhenNothingIsClose() {
        let why = invalidMessage("\(Self.account)\nfrobnicate: yes\n")
        XCTAssertTrue(why.contains("unknown key 'frobnicate'"), why)
        XCTAssertFalse(why.contains("did you mean"), why)
    }

    func testRemovedKeysKeepTheirMigrationErrorOverUnknownKeyNoise() {
        let why = invalidMessage("repo: acme/widgets\nmax_runner: 4\n")
        XCTAssertTrue(why.contains("repo: is gone"), why)
    }

    // MARK: - What stays accepted

    func testBudgetKeysAreRuntimeNamesNotSchemaKeys() throws {
        let yaml = """
            \(Self.account)
            container:
              image: img
            runtimes:
              budget:
                appleContainer: 0.5
            """
        XCTAssertNoThrow(try ConfigLoader.parse(yaml))
    }

    func testTopLevelUserPrefixIsIgnored() throws {
        let yaml = """
            x-common: &common
              note: shared
            \(Self.account)
            x-note: free text
            """
        XCTAssertNoThrow(try ConfigLoader.parse(yaml))
        // Only at the top level.
        XCTAssertTrue(invalidMessage("\(Self.account)\nvm:\n  x-note: 1\n").contains("vm.x-note"))
    }

    func testEmptyAndTemplateConfigsHaveNoUnknownKeys() throws {
        XCTAssertEqual(try ConfigSchema.unknownKeys(in: ""), [])
        XCTAssertEqual(try ConfigSchema.unknownKeys(in: ConfigLoader.template()), [])
        XCTAssertNoThrow(try ConfigLoader.parse(ConfigLoader.template()))
    }

    func testEveryKnownKeyIsAccepted() throws {
        let yaml = """
            version: 1
            accounts:
              - name: github
                forge: github
                scope: acme/widgets
                instance: https://github.example.com
                scale_set:
                  name: kinhin
                  runner_group: mine
              - name: gitea
                forge: gitea
                scope: acme/widgets
                instance: https://gitea.example.com
                allow_insecure_http: false
                labels: [macos:host]
            labels: [self-hosted, macos]
            min_runners: 0
            max_runners: 3
            runners_per_vm: 2
            poll_interval: 30
            auto_resume: true
            token_ttl: 3000
            vm: {cpu: 4, memory_gb: 8, ephemeral: true}
            image: base
            base_image: ghcr.io/cirruslabs/macos-sequoia-base:latest
            images:
              - name: xcode
                base_image: ghcr.io/cirruslabs/macos-tahoe-xcode:latest
                labels: [xcode]
            vm_boot_timeout: 300
            disk_gb: 60
            tart_path: /opt/homebrew/bin/tart
            tart_softnet: false
            reserve: {cpu: 2, memory_gb: 4, disk_gb: 10}
            container: {image: img, cpus: 2, memory_gb: 4, labels: [x], base_image: "ubuntu:24.04"}
            docker: {image: img, cpus: 2, memory_gb: 4, max_slots: 4, base_image: "ubuntu:24.04", platform: linux/amd64}
            runtimes:
              default: tart
              budget: {tart: 0.5, docker: 0.5}
              routes:
                - {pattern: "acme/widgets", runtime: docker}
            provision_script: /tmp/provision.sh
            toolchain_cache: {auto_prune: true, max_age_days: 30, max_gb: 20}
            max_project_images: 4
            projects:
              - pattern: acme/widgets
                repo_file: true
                share_cache: true
                toolchains: {specs: [go@1.23.4], brew: [wget], stacks: [flutter]}
            """
        XCTAssertEqual(try ConfigSchema.unknownKeys(in: yaml), [])
        XCTAssertNoThrow(try ConfigLoader.parse(yaml))
    }

    // MARK: - version

    func testVersionDefaultsToOneAndOneIsAccepted() throws {
        XCTAssertNoThrow(try ConfigLoader.parse(Self.account))
        XCTAssertNoThrow(try ConfigLoader.parse("version: 1\n\(Self.account)"))
        XCTAssertEqual(ConfigLoader.currentVersion, 1)
    }

    func testNonPositiveVersionIsRejected() {
        XCTAssertTrue(invalidMessage("version: 0\n\(Self.account)").contains("version"))
        XCTAssertTrue(invalidMessage("version: soon\n\(Self.account)").contains("version"))
    }

    func testNewerVersionToleratesUnknownKeysButStillValidatesKnownOnes() throws {
        let cfg = try ConfigLoader.parse(
            "version: 2\n\(Self.account)\nmax_runners: 5\nfuture_section:\n  fancy: true\nvm:\n  gpu: 1\n")
        XCTAssertEqual(cfg.maxRunners, 5)
        XCTAssertTrue(
            invalidMessage("version: 2\n\(Self.account)\nmax_runners: 0\nfuture: 1\n").contains("max_runners"))
    }

    // MARK: - Suggestion matching

    func testEditDistance() {
        XCTAssertEqual(ConfigSuggestion.editDistance("kitten", "sitting"), 3)
        XCTAssertEqual(ConfigSuggestion.editDistance("", "abc"), 3)
        XCTAssertEqual(ConfigSuggestion.editDistance("abc", "abc"), 0)
        // A swapped pair is one edit, the commonest typing slip.
        XCTAssertEqual(ConfigSuggestion.editDistance("scpoe", "scope"), 1)
    }

    func testClosestIgnoresCaseAndSeparatorsAndRejectsFarMatches() {
        let keys = ["max_runners", "min_runners", "poll_interval"]
        XCTAssertEqual(ConfigSuggestion.closest(to: "MaxRunners", in: keys), "max_runners")
        XCTAssertEqual(ConfigSuggestion.closest(to: "poll_intervall", in: keys), "poll_interval")
        XCTAssertNil(ConfigSuggestion.closest(to: "frobnicate", in: keys))
        XCTAssertNil(ConfigSuggestion.closest(to: "", in: keys))
        // Short keys get little slack: 'cpu' must not suggest an unrelated 'cpus' sibling twice removed.
        XCTAssertNil(ConfigSuggestion.closest(to: "xyz", in: ["cpu"]))
    }
}
