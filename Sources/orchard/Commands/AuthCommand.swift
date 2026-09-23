import Foundation
import OrchardKit

enum AuthCommand {
    static func run(_ args: [String]) async throws {
        let sub = args.dropFirst().first ?? "set"
        // Platform selection: --gitea targets the Gitea token; default is GitHub.
        let giteaMode = args.contains("--gitea")
        let forge: ForgeID = giteaMode ? .gitea : .github
        let forgeName = giteaMode ? "Gitea access token" : "GitHub PAT"
        switch sub {
        case "set":
            if let token = flag("--token", in: args) {
                try KeychainTokenStore.save(token, forge: forge)
                if giteaMode {
                    notifyDaemonGiteaTokenReplaced(token)
                } else {
                    notifyDaemonTokenReplaced(token)
                }
                print("\(forgeName) stored in Keychain")
            } else {
                print("Paste your \(forgeName) (input hidden), then press Enter:")
                guard let token = String(data: FileHandle.standardInput.availableData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
                    fail("no token entered")
                }
                try KeychainTokenStore.save(token, forge: forge)
                if giteaMode {
                    notifyDaemonGiteaTokenReplaced(token)
                } else {
                    notifyDaemonTokenReplaced(token)
                }
                print("\(forgeName) stored in Keychain")
            }
        case "status":
            if giteaMode {
                guard let token = KeychainTokenStore.load(forge: .gitea) else {
                    print("no Gitea token stored")
                    exit(1)
                }
                let cfg = loadConfigOrExit()
                guard let gitea = cfg.gitea else {
                    fail("no gitea section in config — add it before checking the Gitea token")
                }
                print("Gitea token stored (starts with \(token.prefix(4))…), checking \(gitea.instance)…")
                let client = GiteaClient(credentials: GiteaCredentials(token: token, scope: gitea.scope, instance: gitea.instance))
                do {
                    _ = try await client.fetchRegistrationToken()
                    print("token works against \(gitea.scope) @ \(gitea.instance)")
                } catch {
                    print("token check failed: \(error.localizedDescription)")
                    exit(1)
                }
            } else {
                guard let token = KeychainTokenStore.load() else {
                    print("no token stored")
                    exit(1)
                }
                let cfg = loadConfigOrExit()
                print("token stored (starts with \(token.prefix(4))…), checking…")
                let client = GitHubClient(credentials: GitHubCredentials(token: token, scope: cfg.repo))
                do {
                    _ = try await client.listRunners()
                    print("token works against \(cfg.repo)")
                } catch {
                    print("token check failed: \(error.localizedDescription)")
                    exit(1)
                }
            }
        case "clear":
            KeychainTokenStore.delete(forge: forge)
            print("\(forgeName) removed")
        default:
            fail("unknown auth subcommand '\(sub)' (use set|status|clear)")
        }
    }
}
