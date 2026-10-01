import Foundation

// MARK: - Bitbucket runner package + JDK

extension RunnerBootstrap {
    /// The Bitbucket runner package's layout: one tarball per release
    /// (`atlassian-bitbucket-pipelines-runner-<version>.tar.gz`), unpacked to
    /// `bin/start.sh` (which requires `java` on PATH) next to `bin/runner.jar`.
    /// Atlassian publishes no checksums for it, so the tarball is pinned by
    /// digest (re-pinned deliberately when the version is bumped) and the
    /// JDK — the input that actually executes pipeline code — is verified
    /// against Temurin's per-release SHA-256 (see `temurinJDKDigestCommand`).
    /// Downloads the package for `platform` ("macos" needs no variant; Linux
    /// is also a single universal archive) plus the Temurin 25 JDK for
    /// `jdkPlatform` (Temurin's arch_os: "aarch64_mac", "x64_mac",
    /// "aarch64_linux", "x64_linux"), and
    /// writes the `runner.sh` wrapper the registration scripts exec: it puts
    /// the JDK on PATH, then execs the package's `bin/start.sh`.
    /// `jdkPlatform` is Temurin's arch_os segment ("aarch64_mac",
    /// "x64_mac", "aarch64_linux", "x64_linux").
    static func bitbucketRunnerInstallScript(version: String, jdkVersion: String, jdkPlatform: String) -> String {
        """
        set -euo pipefail

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
          \(temurinJDKDownloadScript(version: jdkVersion, platform: jdkPlatform, file: "jdk.tar.gz").replacingOccurrences(of: "\n", with: "\n  "))
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

    /// The Linux variant: installs into `/opt/bitbucket-runner` (the
    /// container bake), same package and JDK layout. `jdkPlatform` is the
    /// Temurin arch_os segment ("aarch64_linux", "x64_linux").
    static func linuxBitbucketRunnerInstallScript(
        version: String, jdkVersion: String, jdkPlatform: String = "aarch64_linux"
    ) -> String {
        """
        set -euo pipefail
        \(linuxPrerequisitesScript(tools: [("curl", "curl"), ("git", "git")]))
        if [ ! -x /opt/bitbucket-runner/bin/start.sh ]; then
          mkdir -p /opt/bitbucket-runner
          cd /opt/bitbucket-runner
          \(bitbucketRunnerDownloadScript(version: version, file: "runner.tar.gz").replacingOccurrences(of: "\n", with: "\n  "))
          tar xzf runner.tar.gz
          rm runner.tar.gz
          \(temurinJDKDownloadScript(version: jdkVersion, platform: jdkPlatform, file: "jdk.tar.gz").replacingOccurrences(of: "\n", with: "\n  "))
          mkdir -p jdk
          tar xzf jdk.tar.gz -C jdk --strip-components 1
          rm jdk.tar.gz
        fi
        cat > runner.sh <<'LAUNCH'
        #!/bin/bash
        set -euo pipefail
        export PATH="/opt/bitbucket-runner/jdk/bin:$PATH"
        exec /opt/bitbucket-runner/bin/start.sh "$@"
        LAUNCH
        chmod +x runner.sh
        echo "linux bitbucket runner v\(version) installed"
        """
    }

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
    /// The runner's routing was decided at creation: its labels
    /// (`self.hosted`, the platform marker, the account's labels) live on
    /// the forge-side runner, so `start.sh` needs no label arguments. The
    /// runner stays connected across steps (Bitbucket's runner protocol has
    /// no single-job mode); the engine's idle-grace watch deletes the
    /// instance once its runners have been idle, and teardown kills the
    /// process recorded in `runner.pid`. `baseDir` is a shell word (already
    /// quoted, or `/opt/…`); each runner lives in `baseDir/<name>` with its
    /// work directory, credentials, log and pid. `runnerCommand` is the
    /// shell word of the installed `runner.sh` wrapper; `runtime` is the
    /// `--runtime` value Bitbucket's dialog prints (`macos` or
    /// `linux-shell`) — or `auto`, resolved by the guest itself
    /// (Darwin → `macos`, anything else → `linux-shell`), so a tart base
    /// VM works whichever OS its guest runs.
    static func bitbucketRegistrationScript(
        runners: [(name: String, bundle: String)], runtime: String, runnerCommand: String, baseDir: String
    ) -> String {
        // `auto` defers to the guest: a tart base VM may be macOS or Linux.
        let runtimeLine =
            runtime == "auto"
            ? "case \"$(uname -s)\" in Darwin) KINHIN_RUNTIME=macos ;; *) KINHIN_RUNTIME=linux-shell ;; esac"
            : "KINHIN_RUNTIME=\(shellQuote(runtime))"
        var blocks = ""
        for (index, runner) in runners.enumerated() {
            let dir = "\(baseDir)/\(shellQuote(runner.name))"
            blocks += """
                # Bitbucket runner \(index + 1) of \(runners.count)
                mkdir -p \(dir)/work
                cd \(dir)
                (umask 077 && printf '%s' \(shellQuote(runner.bundle)) > credentials)
                nohup /bin/bash -c '
                  IFS="|" read -r WORKSPACE_UUID REPOSITORY_UUID RUNNER_UUID OAUTH_CLIENT_ID OAUTH_CLIENT_SECRET < "$1"
                  \(runtimeLine)
                  exec "$2" \\
                    --accountUuid "$WORKSPACE_UUID" --runnerUuid "$RUNNER_UUID" \\
                    --OAuthClientId "$OAUTH_CLIENT_ID" \\
                    --OAuthClientSecret "$OAUTH_CLIENT_SECRET" \\
                    --workingDirectory "$PWD/work" --runtime "$KINHIN_RUNTIME" $REPOSITORY_UUID_FLAG
                ' bash \(dir)/credentials \(shellQuote(runnerCommand)) \
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

    // MARK: - Downloads

    /// Atlassian publishes no checksums for the runner package; the version
    /// is pinned by digest in `RunnerVersionResolver.pinnedBitbucketRunner`
    /// and re-pinned deliberately when the version is bumped.
    static func bitbucketRunnerDownloadScript(version: String, file: String) -> String {
        let url =
            "https://product-downloads.atlassian.com/software/bitbucket/pipelines/atlassian-bitbucket-pipelines-runner-\(version).tar.gz"
        return verifiedDownloadScript(
            url: url, file: file,
            expectedDigestCommand:
                "echo \(shellQuote(RunnerVersionResolver.pinnedBitbucketRunnerDigests[version] ?? ""))")
    }

    /// Temurin publishes a `<asset>.sha256.txt` sidecar ("<hex>  <asset>",
    /// like Gitea's) next to every release binary — a different request from
    /// the download itself.
    static func temurinJDKDigestCommand(asset: String, jdkVersion: String) -> String {
        let sidecar =
            "https://github.com/adoptium/temurin\(versionPrefix(jdkVersion))-binaries/releases/download/jdk-\(jdkVersion)/\(asset).sha256.txt"
        return "curl --proto-redir '=https' --tlsv1.2 -fsSL \(shellQuote(sidecar)) | awk '{print $1}' | head -1"
    }

    /// `platform` is Temurin's arch_os segment, e.g. "aarch64_mac",
    /// "x64_mac", "aarch64_linux";
    /// the asset name follows Temurin's scheme
    /// (`OpenJDK<jdk>U-jdk_<platform>_hotspot_<version>.tar.gz`).
    static func temurinJDKDownloadScript(version: String, platform: String, file: String) -> String {
        let release = "jdk-\(version)"
        let asset = "OpenJDK\(versionPrefix(version))U-jdk_\(platform)_hotspot_\(temurinVersion(version)).tar.gz"
        let url =
            "https://github.com/adoptium/temurin\(versionPrefix(version))-binaries/releases/download/\(release)/\(asset)"
        return verifiedDownloadScript(
            url: url, file: file,
            expectedDigestCommand: temurinJDKDigestCommand(asset: asset, jdkVersion: version))
    }

    /// "25.0.4.1+1" → "25" (the Temurin repo and release major).
    private static func versionPrefix(_ version: String) -> String {
        String(version.split(separator: ".").first ?? "")
    }

    /// "25.0.4.1+1" → "25.0.4.1_1" (Temurin's build-number file naming).
    private static func temurinVersion(_ version: String) -> String {
        version.replacingOccurrences(of: "+", with: "_")
    }
}
