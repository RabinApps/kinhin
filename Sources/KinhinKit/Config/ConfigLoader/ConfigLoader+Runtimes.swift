import Foundation

// MARK: - runtimes: section

extension ConfigLoader {
    static func parseRuntimes(
        _ runtimes: PartialConfig.PartialRuntimes, container: KinhinConfig.ContainerConfig?,
        docker: KinhinConfig.DockerForgeConfig?
    ) throws -> KinhinConfig.RuntimeConfig {
        var budget: [String: Double] = [:]
        if let entries = runtimes.budget {
            for (runtime, weight) in entries {
                guard weight > 0, weight <= 1 else {
                    throw ConfigError.invalid(
                        "runtimes.budget weights must be in (0, 1], got \(runtime): \(weight)")
                }
                budget[runtime] = weight
            }
        }
        var routes: [KinhinConfig.RuntimeConfig.Route] = []
        for route in runtimes.routes ?? [] {
            routes.append(try parseRoute(route))
        }
        var seenPatterns: Set<String> = []
        for route in routes where !seenPatterns.insert(route.pattern).inserted {
            throw ConfigError.invalid("duplicate runtimes.routes pattern '\(route.pattern)'")
        }
        let referenced = Set(budget.keys).union(routes.map(\.runtime)).union([runtimes.default ?? "tart"])
        let validRuntimes = Set(["tart", "appleContainer", "docker", "host"])
        for name in referenced where !validRuntimes.contains(name) {
            throw ConfigError.invalid(
                "runtimes: unknown runtime '\(name)' (known: tart, appleContainer, docker, host)")
        }
        if runtimes.default == RuntimeID.host.rawValue {
            throw ConfigError.invalid(
                "runtimes.default cannot be 'host' — host execution is opt-in per route (with consent: true)")
        }
        if referenced.contains("appleContainer"), container == nil {
            throw ConfigError.invalid(
                "runtimes routes reference 'appleContainer' but no container: section is configured (it needs an image)"
            )
        }
        if referenced.contains("docker"), docker == nil {
            throw ConfigError.invalid(
                "runtimes routes reference 'docker' but no docker: section is configured (it needs an image)")
        }
        let totalWeight = budget.values.reduce(0, +)
        guard totalWeight <= 1.0001 else {
            throw ConfigError.invalid(
                "runtimes.budget weights sum to \(String(format: "%.2f", totalWeight)) — the total must be <= 1.0")
        }
        return KinhinConfig.RuntimeConfig(
            defaultRuntime: runtimes.default ?? "tart",
            budget: budget,
            routes: routes
        )
    }

    private static func parseRoute(_ route: PartialConfig.PartialRoute) throws -> KinhinConfig.RuntimeConfig.Route {
        guard let pattern = route.pattern, !pattern.isEmpty else {
            throw ConfigError.invalid("runtimes.routes entries need a non-empty pattern")
        }
        guard let runtime = route.runtime, !runtime.isEmpty else {
            throw ConfigError.invalid("runtimes.routes entry '\(pattern)' needs a runtime")
        }
        let segments = pattern.split(separator: "/")
        let isWorkflow = pattern.contains("@")
        if isWorkflow {
            let repoPart = String(pattern.split(separator: "@").first ?? "")
            guard repoPart.split(separator: "/").count == 2, !repoPart.hasSuffix("@") else {
                throw ConfigError.invalid(
                    "runtimes.routes pattern '\(pattern)' must be owner/name@Workflow or owner/name")
            }
        } else {
            guard segments.count == 2, segments.allSatisfy({ !$0.isEmpty }) else {
                throw ConfigError.invalid(
                    "runtimes.routes pattern '\(pattern)' must be owner/name (or owner/name@Workflow)")
            }
        }
        // Host-mode consent gate: running repo code directly on the
        // Mac (unisolated) requires an explicit acknowledgment. Never
        // a default, never implied.
        if runtime == RuntimeID.host.rawValue {
            guard route.consent == true else {
                throw ConfigError.invalid(
                    "runtimes.routes entry '\(pattern)' targets runtime 'host' — jobs run directly on your Mac, unisolated. Review the risk, then add \"consent: true\" to the route"
                )
            }
        } else if route.consent != nil {
            throw ConfigError.invalid(
                "runtimes.routes entry '\(pattern)': consent applies to host routes only")
        }
        return KinhinConfig.RuntimeConfig.Route(pattern: pattern, runtime: runtime, consent: route.consent)
    }
}
