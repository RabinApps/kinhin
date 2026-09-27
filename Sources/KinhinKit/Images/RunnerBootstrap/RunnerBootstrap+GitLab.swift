import Foundation

// MARK: - GitLab runner

extension RunnerBootstrap {
    /// Starts one single-job GitLab runner per name. Each runner was already
    /// created through the API; its authentication token is written to a
    /// private file (never on a command line) and handed to `gitlab-runner
    /// run-single` through `CI_SERVER_TOKEN`. After its one job the runner
    /// deletes itself (`DELETE /api/v4/runners`), which is the "deregistered"
    /// signal the engine's ephemeral watch waits for.
    ///
    /// `binary` and `baseDir` are shell words (already quoted, or `$HOME/…`);
    /// each runner lives in `baseDir/<name>` with its builds, cache, log and
    /// the pid of its background job.
    static func gitlabRegistrationScript(
        instance: String, runners: [(name: String, token: String)], binary: String, baseDir: String
    ) -> String {
        var url = instance
        while url.hasSuffix("/") { url.removeLast() }
        var blocks = ""
        for (index, runner) in runners.enumerated() {
            blocks += """
                # GitLab runner \(index + 1) of \(runners.count)
                mkdir -p \(baseDir)/\(shellQuote(runner.name))
                cd \(baseDir)/\(shellQuote(runner.name))
                (umask 077 && printf '%s' \(shellQuote(runner.token)) > token)
                nohup /bin/bash -c '
                  export CI_SERVER_URL="$1"
                  CI_SERVER_TOKEN="$(cat token)"
                  export CI_SERVER_TOKEN
                  "$0" run-single --name "$2" --executor shell \\
                    --builds-dir "$PWD/builds" --cache-dir "$PWD/cache" --max-builds 1
                  curl -fsS --retry 5 -X DELETE "$1/api/v4/runners" -F "token=<token" >/dev/null
                ' \(binary) \(shellQuote(url)) \(shellQuote(runner.name)) > runner.log 2>&1 < /dev/null &
                echo $! > runner.pid

                """
        }
        return """
            set -euo pipefail

            \(blocks)echo "\(runners.count) gitlab runner(s) started"
            """
    }
}

extension RunnerBootstrap {
    /// Pairs each of an instance's runner names with the token the forge
    /// created for it, in registration order.
    static func gitlabRunners(name: String, runnerCount: Int, tokens: [String: String]) throws
        -> [(name: String, token: String)]
    {
        try FleetEngine.runnerNames(for: name, count: runnerCount).map { runner in
            guard let token = tokens[runner] else {
                throw RuntimeWatchError.registrationFailed(vm: name, stderr: "no GitLab runner token for \(runner)")
            }
            return (runner, token)
        }
    }
}
