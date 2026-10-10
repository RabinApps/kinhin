import Foundation

extension RunnerBootstrap {
    // MARK: - Verified downloads

    /// Shell for downloading a runner agent and refusing to use it unless its
    /// SHA-256 matches the vendor-published digest. Runs inside the guest
    /// (macOS VM or Linux container), so it only relies on `curl` and a
    /// `sha256sum`/`shasum`. Fails closed: if the expected digest cannot be
    /// determined, or differs, the script aborts and deletes the download.
    ///
    /// `expectedDigestCommand` is a shell pipeline that prints the digest.
    /// Checksums come from the vendor's release metadata, a different request
    /// than the download itself; that catches corrupt, truncated, or tampered
    /// downloads (CDN, mirror, proxy), not a compromised vendor account.
    static func verifiedDownloadScript(url: String, file: String, expectedDigestCommand: String) -> String {
        let quotedFile = shellQuote(file)
        return """
            curl --proto-redir '=https' --tlsv1.2 -fsSL \(shellQuote(url)) -o \(quotedFile)
            expected="$(\(expectedDigestCommand) || true)"
            if [ -z "$expected" ]; then
              echo "error: could not determine the published SHA-256 for \(file); refusing to install" >&2
              rm -f \(quotedFile)
              exit 1
            fi
            if command -v sha256sum >/dev/null 2>&1; then
              actual="$(sha256sum \(quotedFile) | cut -d' ' -f1)"
            else
              actual="$(shasum -a 256 \(quotedFile) | cut -d' ' -f1)"
            fi
            if [ "$actual" != "$expected" ]; then
              echo "error: SHA-256 mismatch for \(file) (expected $expected, got $actual)" >&2
              rm -f \(quotedFile)
              exit 1
            fi
            """
    }

    /// GitHub publishes each runner asset's digest in its release notes as
    /// `<!-- BEGIN SHA <platform> -->hex<!-- END SHA <platform> -->`.
    /// `platform` is e.g. "osx-arm64", "linux-arm64", "linux-x64".
    static func githubRunnerDigestCommand(version: String, platform: String) -> String {
        let api = "https://api.github.com/repos/actions/runner/releases/tags/v\(version)"
        return
            "curl --proto-redir '=https' --tlsv1.2 -fsSL \(shellQuote(api)) | grep -o \(shellQuote("BEGIN SHA \(platform) -->[0-9a-f]*")) | head -1 | sed 's/.*-->//'"
    }

    /// Gitea publishes `<asset>.sha256` ("<hex>  <name>") next to every asset.
    static func giteaRunnerDigestCommand(assetURL: String) -> String {
        "curl --proto-redir '=https' --tlsv1.2 -fsSL \(shellQuote(assetURL + ".sha256")) | awk '{print $1}' | head -1"
    }

    static func githubRunnerDownloadScript(version: String, platform: String, file: String) -> String {
        let url =
            "https://github.com/actions/runner/releases/download/v\(version)/actions-runner-\(platform)-\(version).tar.gz"
        return verifiedDownloadScript(
            url: url, file: file,
            expectedDigestCommand: githubRunnerDigestCommand(version: version, platform: platform))
    }

    static func giteaRunnerDownloadScript(version: String, platform: String, file: String) -> String {
        let url = "https://gitea.com/gitea/runner/releases/download/v\(version)/gitea-runner-\(version)-\(platform).xz"
        return verifiedDownloadScript(
            url: url, file: file, expectedDigestCommand: giteaRunnerDigestCommand(assetURL: url))
    }

    /// GitLab publishes one `release.sha256` per release, one
    /// "<hex>\tbinaries/gitlab-runner-<platform>" line per binary.
    static func gitlabRunnerDigestCommand(version: String, platform: String) -> String {
        let sums = "https://gitlab-runner-downloads.s3.amazonaws.com/v\(version)/release.sha256"
        let asset = "binaries/gitlab-runner-\(platform)"
        return
            "curl --proto-redir '=https' --tlsv1.2 -fsSL \(shellQuote(sums)) | awk -v a=\(shellQuote(asset)) '{ sub(/^[*.\\/]+/, \"\", $2) } $2 == a { print $1 }' | head -1"
    }

    /// `platform` is e.g. "darwin-arm64", "linux-amd64".
    static func gitlabRunnerDownloadScript(version: String, platform: String, file: String) -> String {
        let url = "https://gitlab-runner-downloads.s3.amazonaws.com/v\(version)/binaries/gitlab-runner-\(platform)"
        return verifiedDownloadScript(
            url: url, file: file,
            expectedDigestCommand: gitlabRunnerDigestCommand(version: version, platform: platform))
    }

    /// Buildkite publishes one `buildkite-agent-<version>.SHA256SUMS` per
    /// release, one "<hex>  <asset>" line per archive.
    static func buildkiteAgentDigestCommand(version: String, asset: String) -> String {
        let sums =
            "https://github.com/buildkite/agent/releases/download/v\(version)/buildkite-agent-\(version).SHA256SUMS"
        return
            "curl --proto-redir '=https' --tlsv1.2 -fsSL \(shellQuote(sums)) | awk -v a=\(shellQuote(asset)) '{ sub(/^[*.\\/]+/, \"\", $2) } $2 == a { print $1 }' | head -1"
    }

    /// `platform` is e.g. "darwin-arm64", "linux-amd64".
    static func buildkiteAgentDownloadScript(version: String, platform: String, file: String) -> String {
        let asset = "buildkite-agent-\(platform)-\(version).tar.gz"
        let url = "https://github.com/buildkite/agent/releases/download/v\(version)/\(asset)"
        return verifiedDownloadScript(
            url: url, file: file, expectedDigestCommand: buildkiteAgentDigestCommand(version: version, asset: asset))
    }

    /// The Azure Pipelines agent's release notes carry a table of
    /// "[vsts-agent-<platform>-<version>.tar.gz](<url>) | <hex>" rows.
    /// `platform` is e.g. "osx-arm64", "linux-arm64", "linux-x64".
    static func azureAgentDigestCommand(version: String, platform: String) -> String {
        let api = "https://api.github.com/repos/microsoft/azure-pipelines-agent/releases/tags/v\(version)"
        let row = "vsts-agent-\(platform)-\(version).tar.gz) | [0-9a-f]\\{64\\}"
        return
            "curl --proto-redir '=https' --tlsv1.2 -fsSL \(shellQuote(api)) | grep -o \(shellQuote(row)) | head -1 | awk '{print $NF}'"
    }

    static func azureAgentDownloadScript(version: String, platform: String, file: String) -> String {
        let url = "https://download.agent.dev.azure.com/agent/\(version)/vsts-agent-\(platform)-\(version).tar.gz"
        return verifiedDownloadScript(
            url: url, file: file, expectedDigestCommand: azureAgentDigestCommand(version: version, platform: platform))
    }
}
