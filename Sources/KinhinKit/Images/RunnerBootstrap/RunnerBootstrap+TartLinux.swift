import Foundation

// MARK: - Tart Linux VM guest agents

extension RunnerBootstrap {
    // The `kinhin image prepare` bake can target a tart Linux VM (a Linux
    // guest detected via `uname -s`, see `GuestOS`). These scripts install
    // the Linux agent binaries into the SAME $HOME layout the macOS bake
    // uses, because the tart runtimes register runners from `$HOME/…` paths
    // on every VM — only the downloaded binary platform changes
    // (`linux-arm64` instead of `osx-arm64` etc.). The /opt-based scripts in
    // RunnerBootstrap+Linux.swift are the container equivalents (root user,
    // no sudo) and stay separate.

    /// Installs, via apt, whichever of the given tools the guest lacks.
    /// Minimal Linux base images ship neither curl nor CA certificates, and
    /// every download step below needs them. Runs through passwordless sudo
    /// when available (the curated images' `admin` user has it) and plain
    /// apt otherwise (root shells). Idempotent: a no-op once everything is
    /// present.
    static func tartLinuxPrerequisitesScript(tools: [(command: String, package: String)]) -> String {
        let checks = tools.map { "command -v \($0.command) >/dev/null 2>&1 || need=\"$need \($0.package)\"" }
        return
            ([
                "# prerequisites (minimal base images lack them)",
                "need=\"\"",
                "SUDO=\"\"",
                "if [ \"$(id -u)\" -ne 0 ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then",
                "  SUDO=\"sudo\"",
                "fi",
            ] + checks + [
                "[ -e /etc/ssl/certs/ca-certificates.crt ] || need=\"$need ca-certificates\"",
                "if [ -n \"$need\" ]; then",
                "  export DEBIAN_FRONTEND=noninteractive",
                "  $SUDO apt-get update -qq",
                "  $SUDO apt-get install -y --no-install-recommends $need",
                "fi",
            ]).joined(separator: "\n")
    }

    /// Installs the GitHub Actions runner agent (Linux binary) into a tart
    /// Linux base image, one agent directory per concurrent runner — the
    /// same `$HOME` layout as the macOS bake, so registration needs no
    /// changes.
    static func tartLinuxGitHubAgentInstallScript(runnerVersion: String, runnerCount: Int = 1) -> String {
        var dirs = "if [ ! -d \"$HOME/actions-runner\" ]; then"
        for index in 1...max(1, runnerCount) {
            let dir = index == 1 ? "actions-runner" : "actions-runner-\(index)"
            dirs += """

                  mkdir -p "$HOME/\(dir)"
                  cd "$HOME/\(dir)"
                  \(githubRunnerDownloadScript(version: runnerVersion, platform: "linux-arm64", file: "runner.tar.gz").replacingOccurrences(of: "\n", with: "\n      "))
                  tar xzf runner.tar.gz
                  rm runner.tar.gz
                """
        }
        dirs += """

                echo "runner agent v\(runnerVersion) installed"
              else
                echo "runner agent already installed"
              fi
            """

        return """
            set -euo pipefail
            \(tartLinuxPrerequisitesScript(tools: [("curl", "curl"), ("tar", "tar"), ("gzip", "gzip")]))

            RUNNER_VERSION=\(runnerVersion)

            \(dirs)

            # The agent's own dependency script covers the guest's shared libraries.
            for d in "$HOME"/actions-runner*; do
              [ -d "$d" ] || continue
              (cd "$d" && ./bin/installdependencies.sh || echo "warning: installdependencies.sh reported issues in $d")
            done
            """
    }

    /// Installs the Gitea runner binary (Linux) into a tart Linux base
    /// image, same `$HOME/gitea-runner` layout as the macOS bake.
    static func tartLinuxGiteaRunnerInstallScript(version: String) -> String {
        """
        set -euo pipefail
        \(tartLinuxPrerequisitesScript(tools: [("curl", "curl"), ("xz", "xz-utils")]))

        # Gitea runner (host-mode jobs; no Docker needed in the VM).
        if [ ! -x "$HOME/gitea-runner/gitea-runner" ]; then
          mkdir -p "$HOME/gitea-runner"
          cd "$HOME/gitea-runner"
          \(giteaRunnerDownloadScript(version: version, platform: "linux-arm64", file: "runner.xz").replacingOccurrences(of: "\n", with: "\n  "))
          xz -d runner.xz
          chmod +x runner
          mv runner gitea-runner
          ./gitea-runner --version
          echo "gitea runner v\(version) installed"
        else
          echo "gitea runner already installed"
        fi
        """
    }

    /// Installs the GitLab runner binary (Linux) into a tart Linux base
    /// image, same `$HOME/gitlab-runner` layout as the macOS bake.
    static func tartLinuxGitLabRunnerInstallScript(version: String) -> String {
        """
        set -euo pipefail
        \(tartLinuxPrerequisitesScript(tools: [("curl", "curl")]))

        # GitLab runner (shell executor; one job per run-single).
        if [ ! -x "$HOME/gitlab-runner/gitlab-runner" ]; then
          mkdir -p "$HOME/gitlab-runner"
          cd "$HOME/gitlab-runner"
          \(gitlabRunnerDownloadScript(version: version, platform: "linux-arm64", file: "gitlab-runner").replacingOccurrences(of: "\n", with: "\n  "))
          chmod +x gitlab-runner
          ./gitlab-runner --version
          echo "gitlab runner v\(version) installed"
        else
          echo "gitlab runner already installed"
        fi
        """
    }

    /// Installs the Buildkite agent (Linux) into a tart Linux base image,
    /// same `$HOME/buildkite-agent` layout as the macOS bake.
    static func tartLinuxBuildkiteAgentInstallScript(version: String) -> String {
        """
        set -euo pipefail
        \(tartLinuxPrerequisitesScript(tools: [("curl", "curl"), ("git", "git")]))

        # Buildkite agent (one job per agent: --disconnect-after-job).
        if [ ! -x "$HOME/buildkite-agent/buildkite-agent" ]; then
          mkdir -p "$HOME/buildkite-agent"
          cd "$HOME/buildkite-agent"
          \(buildkiteAgentDownloadScript(version: version, platform: "linux-arm64", file: "agent.tar.gz").replacingOccurrences(of: "\n", with: "\n  "))
          tar xzf agent.tar.gz ./buildkite-agent
          rm agent.tar.gz
          ./buildkite-agent --version
          echo "buildkite agent v\(version) installed"
        else
          echo "buildkite agent already installed"
        fi
        """
    }

    /// Installs the Azure Pipelines agent (Linux) into a tart Linux base
    /// image, same `$HOME/azure-agent` layout as the macOS bake.
    static func tartLinuxAzureAgentInstallScript(version: String) -> String {
        """
        set -euo pipefail
        \(tartLinuxPrerequisitesScript(tools: [("curl", "curl"), ("git", "git")]))

        # Azure Pipelines agent (each runner copies it; one job per run.sh --once).
        if [ ! -x "$HOME/azure-agent/config.sh" ]; then
          mkdir -p "$HOME/azure-agent"
          cd "$HOME/azure-agent"
          \(azureAgentDownloadScript(version: version, platform: "linux-arm64", file: "agent.tar.gz").replacingOccurrences(of: "\n", with: "\n  "))
          tar xzf agent.tar.gz
          rm agent.tar.gz
          ./bin/installdependencies.sh
          echo "azure pipelines agent v\(version) installed"
        else
          echo "azure pipelines agent already installed"
        fi
        """
    }

    /// Installs the Bitbucket runner package (Linux layout is a single
    /// universal archive) and the Temurin 25 JDK for aarch64 Linux into a
    /// tart Linux base image, same `$HOME/bitbucket-runner` layout as the
    /// macOS bake — wrapper, package and JDK land exactly where the macOS
    /// registration script expects them.
    static func tartLinuxBitbucketRunnerInstallScript(version: String, jdkVersion: String) -> String {
        """
        set -euo pipefail
        \(tartLinuxPrerequisitesScript(tools: [("curl", "curl"), ("git", "git")]))

        # Bitbucket Pipelines runner (Java-based shell runner; needs a JDK 25).
        if [ ! -x "$HOME/bitbucket-runner/bin/start.sh" ]; then
          mkdir -p "$HOME/bitbucket-runner"
          cd "$HOME/bitbucket-runner"
          \(bitbucketRunnerDownloadScript(version: version, file: "runner.tar.gz").replacingOccurrences(of: "\n", with: "\n  "))
          tar xzf runner.tar.gz
          rm runner.tar.gz
        else
          echo "bitbucket runner already installed"
        fi

        # Temurin JDK 25 (the package's `start.sh` needs `java` on PATH).
        if [ ! -x "$HOME/bitbucket-runner/jdk/bin/java" ]; then
          cd "$HOME/bitbucket-runner"
          \(temurinJDKDownloadScript(version: jdkVersion, platform: "aarch64_linux", file: "jdk.tar.gz").replacingOccurrences(of: "\n", with: "\n  "))
          mkdir -p jdk
          tar xzf jdk.tar.gz -C jdk --strip-components 1
          rm jdk.tar.gz
        else
          echo "Temurin JDK already installed"
        fi

        cat > runner.sh <<'LAUNCH'
        #!/bin/bash
        set -euo pipefail
        export PATH="$HOME/bitbucket-runner/jdk/bin:$PATH"
        exec "$HOME/bitbucket-runner/bin/start.sh" "$@"
        LAUNCH
        chmod +x runner.sh
        echo "bitbucket runner v\(version) installed"
        """
    }
}
