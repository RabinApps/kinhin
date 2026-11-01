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
