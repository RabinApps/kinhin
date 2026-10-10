import Foundation

extension RunnerBootstrap {
    /// Turns off SSH password login in a VM guest (macOS or Linux).
    ///
    /// The curated base images ship `admin`/`admin` with SSH enabled, and
    /// runner VMs share one virtual network, so a job in one VM could log in
    /// to any other with that password. kinhin itself only ever connects with
    /// Tart's key (`BatchMode=yes`), so password and keyboard-interactive
    /// login can go. The drop-in is named `000-…` because sshd takes the first
    /// value it sees and macOS ships its own `100-macos.conf`. The result is
    /// checked with `sshd -T`: a guest whose sshd ignores the drop-in fails
    /// the bake instead of quietly keeping password login.
    ///
    /// On Linux both `sshd -t` and `sshd -T` refuse to run without the
    /// privilege-separation directory `/run/sshd`, which systemd creates only
    /// while `ssh.service` runs. Ubuntu starts that service on demand (socket
    /// activation), so a check before the first SSH connection, or racing the
    /// service, failed with "Missing privilege separation directory" and was
    /// reported as a rejected config or "password login still on" (found by
    /// the e2e Tart Linux lane: about one bake in three). The directory is
    /// created first, as sshd's own unit does; a failure quotes what sshd said.
    static func sshHardeningScript() -> String {
        """
        # Key-only SSH: no password or keyboard-interactive login.
        sudo mkdir -p /etc/ssh/sshd_config.d
        printf '%s\\n' \\
          '# Written by kinhin image prepare: runner VMs share a network, so SSH accepts keys only.' \\
          'PasswordAuthentication no' \\
          'KbdInteractiveAuthentication no' \\
          'AuthenticationMethods publickey' \\
          | sudo tee /etc/ssh/sshd_config.d/000-kinhin-hardening.conf >/dev/null
        SSHD="$(command -v sshd || echo /usr/sbin/sshd)"
        # sshd's config check needs its privilege-separation directory, which exists only while the service runs.
        if [ "$(uname -s)" = Linux ]; then sudo mkdir -p -m 0755 /run/sshd; fi
        if ! CHECK="$(sudo "$SSHD" -t 2>&1)"; then
          sudo rm -f /etc/ssh/sshd_config.d/000-kinhin-hardening.conf
          echo "sshd rejected the hardening config; removed it: $CHECK" >&2
          exit 1
        fi
        # Linux sshd runs as a service and needs a reload; macOS starts one per connection.
        sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd 2>/dev/null || true
        EFFECTIVE="$(sudo "$SSHD" -T 2>&1)" || true
        if ! printf '%s\\n' "$EFFECTIVE" | grep -qi '^passwordauthentication no$'; then
          SAID="$(printf '%s\\n' "$EFFECTIVE" | grep -iE '^passwordauthentication|error|missing|bad' | head -3 | tr '\\n' ' ')"
          echo "sshd did not pick up /etc/ssh/sshd_config.d; SSH password login is still on (sshd -T: $SAID)" >&2
          exit 1
        fi
        """
    }
}
