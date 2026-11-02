import Foundation

/// Docker inside a Linux runner container (`container.docker: true`).
extension RunnerBootstrap {
    // MARK: - Starting dockerd before the runner registers

    /// Starts `dockerd` inside the runner container and waits until `docker info` answers, ahead of the forge's
    /// registration script (the container runs as root, so no sudo). It runs before that script's own
    /// `set -euo pipefail`, so every failure exits explicitly, with the reason on stderr.
    ///
    /// Apple container mounts `/proc/sys` read-only, and dockerd writes `net.ipv4.ip_forward` there, so the script
    /// remounts it read-write, which needs the capabilities `--cap-add ALL` gives the container (a remount that fails
    /// while `/proc/sys` is already writable is fine). dockerd gets its own session and no stdio from the exec, so it
    /// outlives the `container exec` that started it. Idempotent: a daemon that already answers (a re-registration, or
    /// recovery of a running container) is left alone.
    static func linuxDockerDaemonScript(timeoutSeconds: Int = 60) -> String {
        """
        # Docker inside this runner container (container.docker): start dockerd before the runner registers.
        if ! docker info >/dev/null 2>&1; then
          if ! command -v dockerd >/dev/null 2>&1 || ! command -v docker >/dev/null 2>&1; then
            echo "kinhin: container.docker is on but the image has no dockerd; rebuild it with kinhin image prepare --container" >&2
            exit 1
          fi
          # dockerd writes /proc/sys/net/ipv4/ip_forward; /proc/sys is mounted read-only.
          if ! mount -o remount,rw /proc/sys 2>/dev/null && [ ! -w /proc/sys/net/ipv4/ip_forward ]; then
            echo "kinhin: warning: could not remount /proc/sys read-write; dockerd may fail to start" >&2
          fi
          # A pid file left by a daemon that stopped with the container makes dockerd refuse to start.
          if [ -f /var/run/docker.pid ] && ! kill -0 "$(cat /var/run/docker.pid 2>/dev/null)" 2>/dev/null; then
            rm -f /var/run/docker.pid
          fi
          setsid nohup dockerd >/var/log/dockerd.log 2>&1 < /dev/null &
          docker_ready=""
          for _ in $(seq 1 \(timeoutSeconds)); do
            if docker info >/dev/null 2>&1; then
              docker_ready=1
              break
            fi
            sleep 1
          done
          if [ -z "$docker_ready" ]; then
            echo "kinhin: dockerd did not start within \(timeoutSeconds) s; the end of /var/log/dockerd.log:" >&2
            tail -n 10 /var/log/dockerd.log >&2
            exit 1
          fi
          echo "dockerd started"
        fi
        """
    }

    /// The buildx builder an amd64 runner's builds go through (`linuxDockerBuilderScript`).
    static let rosettaBuilderName = "kinhin"

    /// The oldest buildx whose `docker-container` driver takes `default-load=true`.
    static let rosettaBuilderMinimumBuildx = "0.14.0"

    /// Points `docker build` on an amd64 runner (`container.platform: linux/amd64`) at a `docker-container` buildx
    /// builder. dockerd runs under Rosetta there, and its built-in BuildKit cannot start a `RUN` step on the bridge
    /// network: the libnetwork-setkey prestart hook re-executes `/proc/<dockerd>/exe`, which is Rosetta rather than
    /// dockerd ("rosetta error: failed to open elf at -exec-root=/var/run/docker"). A BuildKit container is an
    /// ordinary container, which starts fine. `default-load=true` loads each result into dockerd's image store, as
    /// the built-in builder does. Runs after dockerd answers (creating the builder needs it); the BuildKit container
    /// itself starts on the first build.
    ///
    /// `docker build` ignores `docker buildx use`: it asks buildx for `BUILDX_BUILDER`, or else for the builder named
    /// after the current Docker context. So the script sets both. `BUILDX_BUILDER=kinhin` goes in every baked GitHub
    /// runner directory's `.env` (which `config.sh` keeps and the runner passes to each job) and to login shells, and
    /// a context named `kinhin`, pointing at the same local dockerd, becomes the current one. The context also reaches
    /// tools that run `docker build` with a cleaned environment (no `BUILDX_BUILDER`, not even `HOME`: the CLI then
    /// finds root's config through the user database); a job that sets `DOCKER_HOST` or `DOCKER_CONTEXT` bypasses
    /// it. It needs buildx `rosettaBuilderMinimumBuildx` or later (Ubuntu 24.04 ships
    /// 0.30; Debian 12 has none, Debian 13 has 0.13). Without it, or when the builder cannot be made, the runner still
    /// registers, since `docker run` and pulls work, and says that builds will fail. A builder of that name left with
    /// another driver is replaced.
    static func linuxDockerBuilderScript() -> String {
        let name = rosettaBuilderName
        let minimum = rosettaBuilderMinimumBuildx
        return """
            # Docker under Rosetta (container.platform: linux/amd64): builds go through a docker-container builder,
            # since dockerd's built-in BuildKit cannot start RUN steps under Rosetta.
            buildx_version="$(docker buildx version 2>/dev/null | awk '{print $2}' | sed 's/^v//')"
            if [ -z "$buildx_version" ] \\
              || [ "$(printf '%s\\n' \(minimum) "$buildx_version" | sort -V | head -n 1)" != "\(minimum)" ]; then
              echo "kinhin: warning: docker build fails under Rosetta on this runner: kinhin's builder needs buildx" \\
                "\(minimum) or later (found ${buildx_version:-none}); install docker-buildx in the image" >&2
            elif docker buildx inspect \(name) 2>/dev/null | grep -q '^Driver: *docker-container$' \\
              || { docker buildx rm \(name) >/dev/null 2>&1
                   docker buildx create --name \(name) --driver docker-container --driver-opt default-load=true >/dev/null; }; then
              for runner_dir in /opt/actions-runner /opt/actions-runner-*; do
                [ -d "$runner_dir" ] || continue
                grep -qs '^BUILDX_BUILDER=' "$runner_dir/.env" || echo 'BUILDX_BUILDER=\(name)' >> "$runner_dir/.env"
              done
              echo 'export BUILDX_BUILDER=\(name)' > /etc/profile.d/kinhin-buildx.sh
              { docker context inspect \(name) >/dev/null 2>&1 \\
                  || docker context create \(name) --description "local dockerd; builds via the \(name) buildx builder" \\
                       --docker host=unix:///var/run/docker.sock >/dev/null 2>&1; } \\
                && docker context use \(name) >/dev/null 2>&1 \\
                || echo "kinhin: warning: could not make \(name) the current Docker context; builds need BUILDX_BUILDER" >&2
              echo "docker build uses the \(name) buildx builder"
            else
              echo "kinhin: warning: could not create the \(name) buildx builder; docker build fails under Rosetta" >&2
            fi
            """
    }

    // MARK: - Installing Docker into a baked image

    /// Installs Docker into a Linux image for `container.docker` (baked during `kinhin image prepare --container`):
    /// `docker.io` (the daemon and CLI), `iptables` when missing, and `docker-buildx` / `docker-compose-v2` when the
    /// distribution has them (Ubuntu 24.04 and later do). Skipped entirely when the base image already has `dockerd`,
    /// so a base that ships Docker CE keeps its own packages. Runs as root through apt, like
    /// `linuxPrerequisitesScript`, with services held back (`policy-rc.d`) while the packages install.
    static func linuxDockerInstallScript() -> String {
        """
        # Docker (container.docker): installed unless the base image already has dockerd
        if ! command -v dockerd >/dev/null 2>&1; then
          export DEBIAN_FRONTEND=noninteractive
          apt-get update -qq
          docker_packages="docker.io"
          command -v iptables >/dev/null 2>&1 || docker_packages="$docker_packages iptables"
          for optional in docker-buildx docker-compose-v2; do
            if apt-cache show "$optional" >/dev/null 2>&1; then
              docker_packages="$docker_packages $optional"
            fi
          done
          # Keep the package scripts from starting dockerd in the bake's container (it would fail there, and could
          # leave a pid file in the image): runners start it themselves.
          policy_added=""
          if [ ! -e /usr/sbin/policy-rc.d ]; then
            printf '#!/bin/sh\\nexit 101\\n' > /usr/sbin/policy-rc.d
            chmod +x /usr/sbin/policy-rc.d
            policy_added=1
          fi
          apt-get install -y --no-install-recommends $docker_packages
          [ -z "$policy_added" ] || rm -f /usr/sbin/policy-rc.d
        fi
        dockerd --version
        """
    }
}
