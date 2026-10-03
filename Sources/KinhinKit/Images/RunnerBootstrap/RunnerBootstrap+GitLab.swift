import Foundation

// MARK: - GitLab runner

extension RunnerBootstrap {
    /// Installs the GitLab runner binary into the macOS base image.
    static func gitlabRunnerInstallScript(version: String) -> String {
        """
        set -euo pipefail

        # GitLab runner (shell executor; one job per run-single).
        if [ ! -x "$HOME/gitlab-runner/gitlab-runner" ]; then
          mkdir -p "$HOME/gitlab-runner"
          cd "$HOME/gitlab-runner"
          \(gitlabRunnerDownloadScript(version: version, platform: "darwin-arm64", file: "gitlab-runner").replacingOccurrences(of: "\n", with: "\n  "))
          chmod +x gitlab-runner
          ./gitlab-runner --version
          echo "gitlab runner v\(version) installed"
        else
          echo "gitlab runner already installed"
        fi
        """
    }

    /// Installs the GitLab runner binary into a Linux image (`arch` is
    /// "arm64", or "amd64" for emulated bakes).
    static func linuxGitLabRunnerInstallScript(version: String, arch: String = "arm64") -> String {
        """
        set -euo pipefail
        \(linuxPrerequisitesScript(tools: [("curl", "curl")]))
        if [ ! -x /opt/gitlab-runner/gitlab-runner ]; then
          mkdir -p /opt/gitlab-runner
          cd /opt/gitlab-runner
          \(gitlabRunnerDownloadScript(version: version, platform: "linux-\(arch)", file: "gitlab-runner").replacingOccurrences(of: "\n", with: "\n  "))
          chmod +x gitlab-runner
          ./gitlab-runner --version
        fi
        echo "linux gitlab-runner v\(version) installed"
        """
    }

    /// Starts one single-job GitLab runner per name. Each runner was already
    /// created through the API; its authentication token reaches the runner's
    /// shell on a pipe (never on a command line, never in a file) and is handed
    /// to `gitlab-runner run-single` through `CI_SERVER_TOKEN`. After its one
    /// job the runner deletes itself (`DELETE /api/v4/runners`, token on curl's
    /// stdin), which is the "deregistered" signal the engine's ephemeral watch
    /// waits for.
    ///
    /// Residual exposure: `run-single` itself needs the token for its whole
    /// life, so it stays in that process's environment, which the shell
    /// executor's job inherits. It is not on disk and not in `ps` argv.
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
                printf '%s' \(shellQuote(runner.token)) | nohup /bin/bash -c '
                  IFS= read -r CI_SERVER_TOKEN || true
                  export CI_SERVER_TOKEN
                  export CI_SERVER_URL="$1"
                  "$0" run-single --description "$2" --executor shell \\
                    --builds-dir "$PWD/builds" --cache-dir "$PWD/cache" --max-builds 1 < /dev/null
                  # The token is still in this shell: hand it to curl on stdin, so no file holds it.
                  for attempt in 1 2 3 4 5; do
                    printf %s "$CI_SERVER_TOKEN" |
                      curl -fsS -X DELETE "$1/api/v4/runners" -F "token=<-" >/dev/null && break
                    sleep 2
                  done
                ' \(binary) \(shellQuote(url)) \(shellQuote(runner.name)) > runner.log 2>&1 &
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
