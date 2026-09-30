import Foundation

// MARK: - Bitbucket runner

extension RunnerBootstrap {
    /// Starts one Bitbucket runner per name (macOS shell runner in VMs and
    /// on the host; Linux shell runner in containers). Each runner's
    /// credential bundle — workspace UUID, runner UUID, OAuth client id,
    /// OAuth client secret — was captured when the forge created the runner
    /// (the secret is only ever shown then); the bundle is written to a
    /// private file (umask 077, the runner's own directory) and read back
    /// inside the background job, so the secrets kinhin stores never appear
    /// in the registration script's own process listing. The runner binary
    /// takes the OAuth secret as a command-line argument — the form
    /// Atlassian's own installation dialog prints — so the inner `exec`
    /// expands it there; the VM (or container) is single-tenant and
    /// ephemeral.
    ///
    /// The runner stays connected across steps (Bitbucket's runner protocol
    /// has no single-job mode); the engine's idle-grace watch deletes the
    /// instance once its runners have been idle, and teardown kills the
    /// process recorded in `runner.pid`. `baseDir` is a shell word (already
    /// quoted, or `/opt/…`); each runner lives in `baseDir/<name>` with its
    /// work directory, credentials, log and pid. `runnerCommand` is the
    /// shell word of the installed runner package's launcher (see the
    /// install scripts for the per-runtime paths); `runtime` is the
    /// `--runtime` value Bitbucket's dialog prints (`macos` or
    /// `linux-shell`).
    static func bitbucketRegistrationScript(
        runners: [(name: String, bundle: String)], workspace: String, runtime: String,
        labels: [String], runnerCommand: String, baseDir: String
    ) -> String {
        let labelList = labels.joined(separator: ",")
        var blocks = ""
        for (index, runner) in runners.enumerated() {
            let dir = "\(baseDir)/\(shellQuote(runner.name))"
            blocks += """
                # Bitbucket runner \(index + 1) of \(runners.count)
                mkdir -p \(dir)/work
                cd \(dir)
                (umask 077 && printf '%s' \(shellQuote(runner.bundle)) > credentials)
                nohup /bin/bash -c '
                  IFS="|" read -r WORKSPACE_UUID RUNNER_UUID OAUTH_CLIENT_ID OAUTH_CLIENT_SECRET < "$1"
                  exec "$2" \\
                    --accountUuid "$WORKSPACE_UUID" --runnerUuid "$RUNNER_UUID" \\
                    --OAuthClientId "$OAUTH_CLIENT_ID" \\
                    --OAuthClientSecret "$OAUTH_CLIENT_SECRET" \\
                    --workspace "$3" --runtime "$4" --labels "$5" \\
                    --workingDirectory "$PWD/work"
                ' bash \(dir)/credentials \(shellQuote(runnerCommand)) \\
                  \(shellQuote(workspace)) \(shellQuote(runtime)) \(shellQuote(labelList)) \\
                  > runner.log 2>&1 < /dev/null &
                echo $! > runner.pid

                """
        }
        return """
            set -euo pipefail

            \(blocks)echo "\(runners.count) bitbucket runner(s) started"
            """
    }

    /// Pairs each of an instance's runner names with its credential bundle,
    /// in registration order.
    static func bitbucketRunners(name: String, runnerCount: Int, tokens: [String: String]) throws
        -> [(name: String, bundle: String)]
    {
        try FleetEngine.runnerNames(for: name, count: runnerCount).map { runner in
            guard let bundle = tokens[runner] else {
                throw RuntimeWatchError.registrationFailed(
                    vm: name, stderr: "no Bitbucket credential bundle for \(runner)")
            }
            return (runner, bundle)
        }
    }
}
