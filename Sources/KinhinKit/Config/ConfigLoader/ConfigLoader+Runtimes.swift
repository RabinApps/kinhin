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
        var rawRoutes: [RawRoute] = []
        for route in runtimes.routes ?? [] {
            rawRoutes.append(try parseRoute(route))
        }
        var seenPatterns: Set<String> = []
        for route in rawRoutes where !seenPatterns.insert(route.pattern).inserted {
            throw ConfigError.invalid("duplicate runtimes.routes pattern '\(route.pattern)'")
        }
        let defaultName = runtimes.default ?? RuntimeID.tart.rawValue
        let referencedNames = Set(budget.keys).union(rawRoutes.map(\.runtime)).union([defaultName])
        let known = RuntimeID.allCases.map(\.rawValue)
        for name in referencedNames.sorted() where !known.contains(name) {
            throw ConfigError.invalid(
                "runtimes: unknown runtime '\(name)'\(ConfigSuggestion.hint(for: name, in: known)) "
                    + "(known: \(known.joined(separator: ", ")))")
        }
        // Every name is known past the check above; the throw is unreachable.
        func resolve(_ name: String) throws -> RuntimeID {
            guard let id = RuntimeID(rawValue: name) else {
                throw ConfigError.invalid("runtimes: unknown runtime '\(name)'")
            }
            return id
        }
        let defaultRuntime = try resolve(defaultName)
        let routes = try rawRoutes.map {
            KinhinConfig.RuntimeConfig.Route(pattern: $0.pattern, runtime: try resolve($0.runtime), consent: $0.consent)
        }
        let referenced = Set(try referencedNames.map(resolve))
        if runtimes.default == RuntimeID.host.rawValue {
            throw ConfigError.invalid(
                "runtimes.default cannot be 'host' — host execution is opt-in per route (with consent: true)")
        }
        if referenced.contains(.appleContainer), container == nil {
            throw ConfigError.invalid(
                "runtimes routes reference 'appleContainer' but no container: section is configured (it needs an image)"
            )
        }
        if referenced.contains(.docker), docker == nil {
            throw ConfigError.invalid(
                "runtimes routes reference 'docker' but no docker: section is configured (it needs an image)")
        }
        let totalWeight = budget.values.reduce(0, +)
        guard totalWeight <= 1.0001 else {
            throw ConfigError.invalid(
                "runtimes.budget weights sum to \(String(format: "%.2f", totalWeight)) — the total must be <= 1.0")
        }
        return KinhinConfig.RuntimeConfig(
            defaultRuntime: defaultRuntime,
            budget: budget,
            routes: routes
        )
    }

    /// A route whose runtime name has not yet been checked against `RuntimeID`.
    private struct RawRoute {
        let pattern: String
        let runtime: String
        let consent: Bool?
    }

    private static func parseRoute(_ route: PartialConfig.PartialRoute) throws -> RawRoute {
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
        return RawRoute(pattern: pattern, runtime: runtime, consent: route.consent)
    }
}
