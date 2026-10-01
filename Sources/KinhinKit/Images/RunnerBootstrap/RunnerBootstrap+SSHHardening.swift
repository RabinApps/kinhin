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
        if ! sudo "$SSHD" -t; then
          sudo rm -f /etc/ssh/sshd_config.d/000-kinhin-hardening.conf
          echo "sshd rejected the hardening config; removed it" >&2
          exit 1
        fi
        # Linux sshd runs as a service and needs a reload; macOS starts one per connection.
        sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd 2>/dev/null || true
        if ! sudo "$SSHD" -T | grep -qi '^passwordauthentication no$'; then
          echo "sshd did not pick up /etc/ssh/sshd_config.d (missing 'Include /etc/ssh/sshd_config.d/*'?); SSH password login is still on" >&2
          exit 1
        fi
        """
    }
}
