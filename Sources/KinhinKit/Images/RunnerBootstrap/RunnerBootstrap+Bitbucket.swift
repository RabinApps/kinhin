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

        # Temurin JDK 25 (the package's `start.sh` needs `java` on PATH). The macOS
        # tarball nests the JDK under Contents/Home.
        if [ ! -x "$HOME/bitbucket-runner/jdk/Contents/Home/bin/java" ]; then
          cd "$HOME/bitbucket-runner"
          \(temurinJDKDownloadScript(version: jdkVersion, platform: jdkPlatform, file: "jdk.tar.gz").replacingOccurrences(of: "\n", with: "\n  "))
          mkdir -p jdk
          tar xzf jdk.tar.gz -C jdk --strip-components 1
          rm jdk.tar.gz
        else
          echo "Temurin JDK already installed"
        fi

        cd "$HOME/bitbucket-runner"
        \(bitbucketLauncherScript(root: #""$HOME/bitbucket-runner""#))
        echo "bitbucket runner v\(version) installed"
        """
    }

    /// The Linux variant: installs into `/opt/bitbucket-runner` (the
    /// container bake), same package and JDK layout. `jdkPlatform` is the
    /// Temurin arch_os segment of the container's `LinuxPlatform`
    /// ("aarch64_linux" for arm64 containers, "x64_linux" for amd64).
    static func linuxBitbucketRunnerInstallScript(
        version: String, jdkVersion: String, jdkPlatform: String = "aarch64_linux"
    ) -> String {
        """
        set -euo pipefail
        \(linuxPrerequisitesScript(tools: [("curl", "curl"), ("git", "git")]))
        mkdir -p /opt/bitbucket-runner
        cd /opt/bitbucket-runner
        if [ ! -x /opt/bitbucket-runner/bin/start.sh ]; then
          \(bitbucketRunnerDownloadScript(version: version, file: "runner.tar.gz").replacingOccurrences(of: "\n", with: "\n  "))
          tar xzf runner.tar.gz
          rm runner.tar.gz
        fi
        if [ ! -x /opt/bitbucket-runner/jdk/bin/java ]; then
          \(temurinJDKDownloadScript(version: jdkVersion, platform: jdkPlatform, file: "jdk.tar.gz").replacingOccurrences(of: "\n", with: "\n  "))
          mkdir -p jdk
          tar xzf jdk.tar.gz -C jdk --strip-components 1
          rm jdk.tar.gz
        fi
        \(bitbucketLauncherScript(root: "/opt/bitbucket-runner"))
        echo "linux bitbucket runner v\(version) installed"
        """
    }

    /// Writes `runner.sh` into the current directory: the wrapper every
    /// registration script execs. It points `JAVA_HOME` and `PATH` at the
    /// bundled Temurin JDK (macOS tarballs nest it under `Contents/Home`,
    /// Linux ones do not), then execs the package's `bin/start.sh`. `root`
    /// is the install directory as a shell word.
    static func bitbucketLauncherScript(root: String) -> String {
        """
        cat > runner.sh <<'LAUNCH'
        #!/bin/bash
        set -euo pipefail
        JDK=\(root)/jdk
        if [ -d "$JDK/Contents/Home" ]; then JDK="$JDK/Contents/Home"; fi
        export JAVA_HOME="$JDK"
        export PATH="$JDK/bin:$PATH"
        exec \(root)/bin/start.sh "$@"
        LAUNCH
        chmod +x runner.sh
        """
    }

    /// Starts one Bitbucket runner per name (macOS shell runner in VMs and
    /// on the host; Linux shell runner in containers). Each runner's
    /// credential bundle — workspace UUID, runner UUID, OAuth client id,
    /// OAuth client secret — was captured when the forge created the runner
    /// (the secret is only ever shown then); the bundle is written to a
    /// private file (umask 077, the runner's own directory) and read back
    /// inside the background job, which deletes the file straight away, so the
    /// secrets kinhin stores never appear in the registration script's own
    /// process listing nor stay on disk for job steps. The runner binary
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
    ///
    /// The script fails (exit 1, with each dead runner's log) when a runner
    /// is no longer alive after `startupGrace` seconds, so a bad credential,
    /// a missing JDK or a wrong path is a registration failure rather than a
    /// started-looking instance that never connects. `expectedPlatform` is
    /// the platform label the runners were created with (`macos` or
    /// `linux.shell`); a guest of the other OS fails registration with a
    /// message instead of idling under labels no step can match.
    static func bitbucketRegistrationScript(
        runners: [(name: String, bundle: String)], runtime: String, runnerCommand: String, baseDir: String,
        expectedPlatform: String? = nil, startupGrace: Int = 5
    ) -> String {
        var guestGuard = ""
        if let expectedPlatform {
            guestGuard = """
                case "$(uname -s)" in Darwin) KINHIN_GUEST=macos ;; *) KINHIN_GUEST=linux.shell ;; esac
                if [ "$KINHIN_GUEST" != \(shellQuote(expectedPlatform)) ]; then
                  echo "this guest is $KINHIN_GUEST but its Bitbucket runners were created with the \(expectedPlatform) label; add a matching label (for example linux) to the pool or image labels"
                  exit 1
                fi

                """
        }
        var blocks = ""
        var checks = ""
        for (index, runner) in runners.enumerated() {
            let dir = "\(baseDir)/\(shellQuote(runner.name))"
            // The inner script receives the credential file, the runner
            // command and the runtime as arguments ($1..$3), so none of them
            // need quoting inside the single-quoted `bash -c` body.
            blocks += """
                # Bitbucket runner \(index + 1) of \(runners.count)
                mkdir -p \(dir)/work
                cd \(dir)
                (umask 077 && printf '%s' \(shellQuote(runner.bundle)) > credentials)
                nohup /bin/bash -c '
                  IFS="|" read -r WORKSPACE_UUID REPOSITORY_UUID RUNNER_UUID OAUTH_CLIENT_ID OAUTH_CLIENT_SECRET < "$1"
                  # Read once, then gone: job steps must not find the client secret on disk.
                  rm -f "$1"
                  runner_command="$2"
                  runtime="$3"
                  if [ "$runtime" = auto ]; then
                    case "$(uname -s)" in Darwin) runtime=macos ;; *) runtime=linux-shell ;; esac
                  fi
                  set -- "$runner_command" --accountUuid "$WORKSPACE_UUID" --runnerUuid "$RUNNER_UUID" \\
                    --OAuthClientId "$OAUTH_CLIENT_ID" --OAuthClientSecret "$OAUTH_CLIENT_SECRET" \\
                    --workingDirectory "$PWD/work" --runtime "$runtime"
                  if [ -n "$REPOSITORY_UUID" ]; then set -- "$@" --repositoryUuid "$REPOSITORY_UUID"; fi
                  exec "$@"
                ' bash \(dir)/credentials \(runnerCommand) \(shellQuote(runtime)) \\
                  > runner.log 2>&1 < /dev/null &
                echo $! > runner.pid

                """
            checks += """
                if ! kill -0 "$(cat \(dir)/runner.pid)" 2>/dev/null; then
                  echo "bitbucket runner \(runner.name) exited during start-up:"
                  tail -n 20 \(dir)/runner.log
                  failed=1
                fi

                """
        }
        return """
            set -euo pipefail

            \(guestGuard)\(blocks)# A runner that dies at once (no JDK, bad path or credentials) must fail
            # registration with its own output, not look started.
            sleep \(startupGrace)
            failed=0
            \(checks)if [ "$failed" -ne 0 ]; then exit 1; fi
            echo "\(runners.count) bitbucket runner(s) started"
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
