import Foundation

extension ConfigLoader {
    /// Forges whose runners can only run one job and then remove themselves
    /// need an ephemeral VM: with `vm.ephemeral: false` nothing watches the
    /// instance, so its runner leaves after the first job and the VM idles
    /// for good, still counted against the fleet cap.
    ///
    /// GitLab's registration script always runs `run-single --max-builds 1`
    /// and deletes the runner afterwards; that has no persistent variant.
    static func validateEphemeralForges(_ cfg: KinhinConfig) throws {
        guard !cfg.vm.ephemeral else { return }
        for account in cfg.accounts where account.forge == .gitlab {
            throw ConfigError.invalid(
                "account '\(account.name)': GitLab runners take one job and delete themselves, so vm.ephemeral "
                    + "must be true (a persistent VM would sit idle after its first job)")
        }
    }
}
