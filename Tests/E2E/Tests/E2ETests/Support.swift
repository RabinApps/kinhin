import E2ESupport
import Testing

/// Everything that starts real infrastructure (forge containers, runner guests, image bakes) nests under this suite.
/// `.serialized` applies to nested suites too, so they run one at a time: two forge stacks and a bake on one Mac
/// would fight over CPU, memory and the container runtimes, and make timeouts meaningless.
@Suite("Real infrastructure", .serialized, .enabled(if: E2E.enabled), ImageCleanup())
struct Infra {}

/// Removes every runner image the suites baked once the whole infrastructure suite has finished (or failed).
struct ImageCleanup: SuiteTrait, TestScoping {
    var isRecursive: Bool { false }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        do {
            try await function()
        } catch {
            await ImageBaker.shared.removeAll()
            throw error
        }
        await ImageBaker.shared.removeAll()
    }
}

extension Tag {
    @Tag static var lifecycle: Self
    @Tag static var fleet: Self
    @Tag static var cli: Self
    @Tag static var security: Self
    @Tag static var toolchain: Self
    @Tag static var coverage: Self
    @Tag static var saas: Self
}

/// One cell of the forge × runtime matrix.
struct LifecycleCase: Sendable, CustomTestStringConvertible {
    let forge: ForgeKind
    let runtime: RuntimeKind
    var testDescription: String { "\(forge) on \(runtime)" }

    /// Every cell this machine can run. `KINHIN_E2E_FORGES` / `KINHIN_E2E_RUNTIMES` narrow it. GitLab CE is heavy
    /// (GBs, minutes to boot), so it runs only when asked for by name or with `KINHIN_E2E_HEAVY=1`. GitHub runs only
    /// when `KINHIN_E2E_GITHUB_TOKEN` and `KINHIN_E2E_GITHUB_REPO` are set.
    static let all: [LifecycleCase] = {
        let heavy = E2E.flag("KINHIN_E2E_HEAVY") != nil
        var cases: [LifecycleCase] = []
        for forge in ForgeKind.allCases {
            guard E2E.selected("KINHIN_E2E_FORGES", forge.rawValue) else { continue }
            if forge == .gitlab, !heavy, E2E.flag("KINHIN_E2E_FORGES") == nil { continue }
            if forge == .github, !GitHubFixture.isConfigured { continue }
            for runtime in RuntimeKind.allCases {
                guard runtime.isAvailable, E2E.selected("KINHIN_E2E_RUNTIMES", runtime.rawValue) else { continue }
                cases.append(LifecycleCase(forge: forge, runtime: runtime))
            }
        }
        return cases
    }()
}
