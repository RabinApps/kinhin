import Foundation

/// What kind of problem an error represents, independent of which subsystem
/// threw it. Front ends use it to pick an exit code or a remediation hint
/// without importing every error type.
public enum ErrorCategory: Equatable, Sendable {
    /// The config file is missing, unreadable, or invalid.
    case config
    /// A forge rejected the token, or none is stored.
    case auth
    /// A runtime, image, daemon, or engine failure.
    case runtime
    case other

    public init(_ error: Error) {
        switch error {
        case is ConfigError, is ConfigEditError:
            self = .config
        case is GitHubError, is GiteaError, is GitLabError, is BuildkiteError, is AzureDevOpsError,
            is BitbucketError, is KeychainTokenStore.TokenError:
            self = .auth
        case is TartError, is ImageError, is RuntimeWatchError, is ContainerManagerError, is EngineError,
            is Daemon.DaemonError, is RPCError, is ShellError, is RuntimeInstallerError:
            self = .runtime
        default:
            self = .other
        }
    }
}
