import Foundation

/// Scripts injected into VMs over SSH to turn them into GitHub Actions runners.
public enum RunnerBootstrap {
    /// Register and start `runnerCount` runner processes in the VM. GitHub's
    /// model is one job per runner process, so density (many-to-one) comes
    /// from registering several runners, each with its own agent directory
    /// and work directory. `runnerCount = 1` produces exactly the classic
    /// single-runner script. `run.sh` runs in the foreground; because the
    /// SSH session must return, each runner is launched detached with nohup.
    public static func registrationScript(
        configureURL: String,
        token: String,
        labels: [String],
        ephemeral: Bool,
        name: String,
        runnerCount: Int = 1
    ) -> String {
        let labelList = labels.joined(separator: ",")
        let ephemeralFlag = ephemeral ? "--ephemeral " : ""

        guard runnerCount > 1 else {
            return """
            set -euo pipefail
            cd ~/actions-runner

            # Register (idempotent: remove stale config first).
            if [ -f .runner ]; then
              ./config.sh remove --token '\(token)' >/dev/null 2>&1 || true
            fi
            ./config.sh --url \(configureURL) \\
                        --token '\(token)' \\
                        --labels '\(labelList)' \\
                        --name '\(name)' \\
                        --unattended \\
                        --replace \\
                        \(ephemeralFlag)--work _work >/dev/null

            # Start serving jobs, detached from this SSH session.
            nohup ./run.sh > run.log 2>&1 &
            echo "runner started"
            """
        }

        var registrations = ""
        for index in 1 ... runnerCount {
            let runnerName = "\(name)-r\(index)"
            let dir = "~/actions-runner-\(index)"
            registrations += """
            # Runner \(index) of \(runnerCount).
            cd \(dir)
            if [ -f .runner ]; then
              ./config.sh remove --token '\(token)' >/dev/null 2>&1 || true
            fi
            ./config.sh --url \(configureURL) \\
                        --token '\(token)' \\
                        --labels '\(labelList)' \\
                        --name '\(runnerName)' \\
                        --unattended \\
                        --replace \\
                        \(ephemeralFlag)--work _work-\(index) >/dev/null

            nohup ./run.sh > run-\(index).log 2>&1 &

            """
        }
        return """
        set -euo pipefail

        # One runner agent directory per process (config.sh refuses shared dirs).
        \(registrations)echo "\(runnerCount) runners started"
        """
    }

    /// Installs the GitHub Actions runner agent into a base image (used by
    /// `orchard image prepare`). `runnerCount` pre-creates one agent directory
    /// per concurrent runner so first boot doesn't download N times.
    public static func installScript(runnerVersion: String, runnerCount: Int = 1) -> String {
        var dirs = "if [ ! -d \"$HOME/actions-runner\" ]; then"
        for index in 1 ... max(1, runnerCount) {
            let dir = index == 1 ? "actions-runner" : "actions-runner-\(index)"
            dirs += """

              mkdir -p "$HOME/\(dir)"
              cd "$HOME/\(dir)"
              ARCH="arm64"
              curl -sL "https://github.com/actions/runner/releases/download/v\(runnerVersion)/actions-runner-osx-arm64-\(runnerVersion).tar.gz" -o runner.tar.gz
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

        RUNNER_VERSION=\(runnerVersion)

        \(dirs)

        # Runners need full disk access for some workloads; document, don't force.
        # Ensure autologin-friendly settings for the admin user.
        sudo -n true 2>/dev/null || echo "note: sudo may prompt for password once"
        """
    }

    /// Installs the Gitea runner binary (gitea-runner, formerly act_runner)
    /// into the base image so any VM can serve Gitea Actions. Kept separate
    /// from the GitHub agent install; both run during `orchard image prepare`.
    public static func giteaRunnerInstallScript(version: String) -> String {
        """
        set -euo pipefail

        # Gitea runner (host-mode jobs; no Docker needed on macOS).
        if [ ! -x "$HOME/gitea-runner/gitea-runner" ]; then
          mkdir -p "$HOME/gitea-runner"
          cd "$HOME/gitea-runner"
          curl -sL "https://gitea.com/gitea/runner/releases/download/v\(version)/gitea-runner-\(version)-darwin-arm64.xz" -o runner.xz
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

    /// Registers and starts N Gitea runner processes in a VM via
    /// `act_runner register --no-interactive` + `daemon`. Gitea has no
    /// --ephemeral, so the registration writes .runner once and the daemon
    /// runs until the lifecycle watch tears the VM down after the job.
    public static func giteaRegistrationScript(instance: String, token: String, labels: [String], name: String, runnerCount: Int = 1) -> String {
        let labelList = labels.joined(separator: ",")
        var blocks = ""
        for index in 1 ... max(1, runnerCount) {
            let runnerName = runnerCount == 1 ? name : "\(name)-r\(index)"
            let dir = runnerCount == 1 ? "$HOME/gitea-runner" : "$HOME/gitea-runner-\(index)"
            blocks += """
            # Gitea runner \(index) of \(runnerCount)
            mkdir -p \(dir)
            cd \(dir)
            if [ ! -x gitea-runner ]; then
              cp "$HOME/gitea-runner/gitea-runner" gitea-runner
            fi
            rm -f .runner
            ./gitea-runner register --no-interactive \
              --instance \(instance) \
              --token '\(token)' \
              --name '\(runnerName)' \
              --labels '\(labelList)' >/dev/null
            nohup ./gitea-runner daemon > daemon-\(index).log 2>&1 &

            """
        }
        return """
        set -euo pipefail

        \(blocks)echo "\(max(1, runnerCount)) gitea runner(s) started"
        """
    }

    /// Base-image tweaks: disable sleep, enable SSH, autologin hint.
    public static func prepareScript() -> String {
        """
        set -euo pipefail

        # Disable sleep so runner VMs never stall mid-job.
        sudo pmset -a disablesleep 1 || true

        # Make sure Remote Login (SSH) is on.
        sudo systemsetup -setremotelogin on 2>/dev/null || true

        echo "base image prepared"
        """
    }

    // MARK: - Linux (Apple container runtime)

    /// The agent architecture inside Linux containers: `container` on Apple
    /// silicon runs arm64 Linux images.
    public static let linuxRunnerArch = "arm64"

    /// Installs the GitHub Actions runner agent into a Linux image for the
    /// Apple-container runtime (baked during `orchard image prepare` when a
    /// GitHub credential exists). Mirrors installScript but for Linux tarballs.
    public static func linuxGitHubAgentInstallScript(runnerVersion: String) -> String {
        """
        set -euo pipefail
        mkdir -p /opt/actions-runner
        cd /opt/actions-runner
        if [ ! -x ./config.sh ]; then
          curl -sL "https://github.com/actions/runner/releases/download/v\(runnerVersion)/actions-runner-linux-arm64-\(runnerVersion).tar.gz" -o runner.tar.gz
          tar xzf runner.tar.gz
          rm runner.tar.gz
          ./bin/installdependencies.sh || echo "warning: installdependencies.sh reported issues"
        fi
        echo "linux actions-runner v\(runnerVersion) installed"
        """
    }

    /// Installs the Gitea runner binary into a Linux image (gitea-runner,
    /// formerly act_runner — linux-arm64 build).
    public static func linuxGiteaRunnerInstallScript(version: String) -> String {
        """
        set -euo pipefail
        if [ ! -x /opt/gitea-runner/gitea-runner ]; then
          mkdir -p /opt/gitea-runner
          cd /opt/gitea-runner
          curl -sL "https://gitea.com/gitea/runner/releases/download/v\(version)/gitea-runner-\(version)-linux-arm64.xz" -o runner.xz
          xz -d runner.xz
          chmod +x runner
          mv runner gitea-runner
          ./gitea-runner --version
        fi
        echo "linux gitea-runner v\(version) installed"
        """
    }

    /// GitHub registration inside a Linux container. The agent directory is
    /// baked at /opt/actions-runner; registration runs as root (the default
    /// container user), so config.sh needs --runasservice=false semantics —
    /// plain unattended registration + foreground nohup run.sh, same shape
    /// as the VM script.
    public static func linuxGitHubRegistrationScript(
        configureURL: String,
        token: String,
        labels: [String],
        ephemeral: Bool,
        name: String,
        runnerCount: Int = 1
    ) -> String {
        let labelList = labels.joined(separator: ",")
        let ephemeralFlag = ephemeral ? "--ephemeral " : ""
        var blocks = ""
        for index in 1 ... max(1, runnerCount) {
            let runnerName = runnerCount == 1 ? name : "\(name)-r\(index)"
            let dir = runnerCount == 1 ? "/opt/actions-runner" : "/opt/actions-runner-\(index)"
            blocks += """
            # GitHub runner \(index) of \(max(1, runnerCount))
            mkdir -p "\(dir)"
            cd "\(dir)"
            if [ ! -x ./config.sh ]; then
              cp -a /opt/actions-runner/. "\(dir)" 2>/dev/null || true
            fi
            if [ -f .runner ]; then
              ./config.sh remove --token '\(token)' >/dev/null 2>&1 || true
            fi
            ./config.sh --url \(configureURL) \\
                        --token '\(token)' \\
                        --labels '\(labelList)' \\
                        --name '\(runnerName)' \\
                        --unattended \\
                        --replace \\
                        \(ephemeralFlag)--work /opt/work-\(index) >/dev/null
            nohup ./run.sh > run-\(index).log 2>&1 &

            """
        }
        return """
        set -euo pipefail

        \(blocks)echo "\(max(1, runnerCount)) linux runner(s) started"
        """
    }

    /// Gitea registration inside a Linux container (gitea-runner register
    /// --no-interactive + daemon; no --ephemeral exists upstream).
    public static func linuxGiteaRegistrationScript(instance: String, token: String, labels: [String], name: String, runnerCount: Int = 1) -> String {
        let labelList = labels.joined(separator: ",")
        var blocks = ""
        for index in 1 ... max(1, runnerCount) {
            let runnerName = runnerCount == 1 ? name : "\(name)-r\(index)"
            let dir = runnerCount == 1 ? "/opt/gitea-runner" : "/opt/gitea-runner-\(index)"
            blocks += """
            # Gitea runner \(index) of \(max(1, runnerCount))
            mkdir -p "\(dir)"
            cd "\(dir)"
            if [ ! -x gitea-runner ]; then
              cp /opt/gitea-runner/gitea-runner gitea-runner
            fi
            rm -f .runner
            ./gitea-runner register --no-interactive \\
              --instance \(instance) \\
              --token '\(token)' \\
              --name '\(runnerName)' \\
              --labels '\(labelList)' >/dev/null
            nohup ./gitea-runner daemon > daemon-\(index).log 2>&1 &

            """
        }
        return """
        set -euo pipefail

        \(blocks)echo "\(max(1, runnerCount)) linux gitea runner(s) started"
        """
    }
}
