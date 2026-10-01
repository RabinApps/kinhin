import Foundation

// MARK: - Helper entries

/// One id the per-job `kinhin-toolchain` helper can install: a catalog tool
/// or stack, with install bodies rendered by the same generators
/// `image prepare` uses, so the helper and the baked path never drift.
struct ToolchainHelperEntry: Sendable, Equatable {
    /// Replaced at runtime with the job's validated `@version`.
    static let versionSentinel = "__KINHIN_VERSION__"
    /// Replaced at runtime with a validated pass-through mise spec.
    static let specSentinel = "__KINHIN_SPEC__"

    let id: String
    let summary: String
    let requires: [ToolchainRequirement]
    /// Install body for the bare id (catalog default version).
    let defaultBody: String
    /// Install body carrying `versionSentinel`; nil when the installer
    /// ignores versions (brew, apt, gem, unversioned stacks).
    let versionedBody: String?
    /// Cache-env variables the body exports, persisted for later job steps.
    let cacheVariables: [String]

    /// Every catalog tool and stack that installs on `platform`, in catalog order.
    static func entries(platform: ToolchainPlatform, mountPath: String) -> [ToolchainHelperEntry] {
        func render(_ config: KinhinConfig.ToolchainsConfig) -> (body: String, variables: [String]) {
            let selection = ToolchainCatalog.selection(from: config, platform: platform, mountPath: mountPath)
            return (body(for: selection, platform: platform, mountPath: mountPath), selection.cacheEnvs.map(\.variable))
        }

        var out: [ToolchainHelperEntry] = []
        for tool in ToolchainCatalog.tools where tool.platforms.contains(platform) {
            let plain = render(.init(specs: [tool.id]))
            var versioned: String? = nil
            switch tool.installer(for: platform) {
            case .mise, .npm:
                versioned = render(.init(specs: ["\(tool.id)@\(versionSentinel)"])).body
            case .brew, .gem, .apt:
                break
            }
            out.append(
                ToolchainHelperEntry(
                    id: tool.id, summary: tool.summary, requires: tool.requires, defaultBody: plain.body,
                    versionedBody: versioned, cacheVariables: plain.variables))
        }
        for stack in ToolchainCatalog.stacks where stack.platforms.contains(platform) {
            let plain = render(.init(stacks: [stack.id]))
            let versioned =
                stack.versionKind == nil ? nil : render(.init(stacks: ["\(stack.id)@\(versionSentinel)"])).body
            out.append(
                ToolchainHelperEntry(
                    id: stack.id, summary: stack.summary, requires: stack.requires, defaultBody: plain.body,
                    versionedBody: versioned, cacheVariables: plain.variables))
        }
        return out
    }

    /// The install body for an unknown id, passed through to mise verbatim.
    static func passThroughBody(platform: ToolchainPlatform, mountPath: String) -> String {
        let selection = ToolchainCatalog.selection(
            from: .init(specs: [specSentinel]), platform: platform, mountPath: mountPath)
        return body(for: selection, platform: platform, mountPath: mountPath)
    }

    private static func body(for selection: ManagedToolchainSelection, platform: ToolchainPlatform, mountPath: String)
        -> String
    {
        switch platform {
        case .macOS: return RunnerBootstrap.managedToolchainsInstallScript(selection: selection, mountPath: mountPath)
        case .linux:
            return RunnerBootstrap.linuxManagedToolchainsInstallScript(selection: selection, mountPath: mountPath)
        }
    }
}

// MARK: - Helper script

extension RunnerBootstrap {
    /// Where every prepared image carries the per-job helper.
    static let toolchainHelperPath = "/usr/local/bin/kinhin-toolchain"
    /// Heredoc delimiter for embedded install bodies.
    static let toolchainHelperBodyDelimiter = "KINHIN_TOOLCHAIN_BODY"

    /// The `kinhin-toolchain` helper baked into every image: a workflow step
    /// runs `kinhin-toolchain install node@22 pnpm` to install only what that
    /// job needs, reusing the catalog's install bodies (and the shared host
    /// cache when `share_cache` mounts it). New PATH entries and cache envs
    /// are appended to `$GITHUB_PATH`/`$GITHUB_ENV` so later steps see them.
    /// Bash 3.2-compatible: macOS guests run the system bash.
    static func toolchainHelperScript(platform: ToolchainPlatform, mountPath: String) -> String {
        let entries = ToolchainHelperEntry.entries(platform: platform, mountPath: mountPath)
        let width = (entries.map(\.id.count).max() ?? 0) + 2
        let listing = entries.map { entry -> String in
            let pad = String(repeating: " ", count: max(1, width - entry.id.count))
            let version = entry.versionedBody == nil ? "" : " [@version]"
            return entry.id + pad + entry.summary + version
        }

        var bodyCases: [String] = []
        for entry in entries {
            bodyCases.append(helperCase("\(entry.id):0", body: entry.defaultBody))
            if let versioned = entry.versionedBody {
                bodyCases.append(helperCase("\(entry.id):1", body: versioned))
            }
        }
        bodyCases.append(
            helperCase(
                "*:passthrough", body: ToolchainHelperEntry.passThroughBody(platform: platform, mountPath: mountPath)))

        let knownIDs = entries.map { "'\($0.id)'" }.joined(separator: "|")
        let requireCases = entries.filter { !$0.requires.isEmpty }.map {
            "  '\($0.id)') echo \($0.requires.map(\.toolID).joined(separator: " ")) ;;"
        }
        let variableCases = entries.filter { !$0.cacheVariables.isEmpty }.map {
            "  '\($0.id)') echo \($0.cacheVariables.joined(separator: " ")) ;;"
        }
        let providers = ToolchainRequirement.allCases.map(\.toolID).joined(separator: " ")

        return """
            #!/bin/bash
            # kinhin-toolchain: per-job installs from kinhin's toolchain catalog (\(platform.rawValue)).
            # Baked by `kinhin image prepare`; print it on the host with `kinhin toolchains helper`.
            set -euo pipefail

            KT_VERSION_SENTINEL='\(ToolchainHelperEntry.versionSentinel)'
            KT_SPEC_SENTINEL='\(ToolchainHelperEntry.specSentinel)'
            KT_PROVIDERS='\(providers)'
            KT_ORIG_PATH="$PATH"
            KT_PERSISTED_PATHS=':'
            export PATH="$HOME/.local/share/mise/shims:$PATH"

            kt_die() {
              echo "kinhin-toolchain: $*" >&2
              exit 1
            }

            kt_usage() {
              cat <<'KT_USAGE'
            usage: kinhin-toolchain install <id[@version]>...
                   kinhin-toolchain list

            Installs catalog toolchains for this job only. Unknown ids pass through to
            `mise use --global`. New PATH entries and cache variables are appended to
            $GITHUB_PATH / $GITHUB_ENV so later workflow steps see them.
            KT_USAGE
            }

            kt_list() {
              cat <<'KT_LIST'
            \(listing.joined(separator: "\n"))
            KT_LIST
            }

            # kt_body ID MODE: print the install body (MODE 0 = default, 1 = versioned).
            kt_body() {
              case "$1:$2" in
            \(bodyCases.joined(separator: "\n"))
              *) return 1 ;;
              esac
            }

            kt_known() {
              case "$1" in
              \(knownIDs.isEmpty ? "''" : knownIDs)) return 0 ;;
              *) return 1 ;;
              esac
            }

            kt_requires() {
              case "$1" in
            \(requireCases.joined(separator: "\n"))
              *) ;;
              esac
            }

            kt_cache_vars() {
              case "$1" in
            \(variableCases.joined(separator: "\n"))
              *) ;;
              esac
            }

            # Runs after each body inside its shell: records PATH and cache envs.
            KT_EPILOGUE='
            printf "%s" "$PATH" > "$KT_STATE/path"
            for kt_v in $KT_VARS; do
              if [ -n "${!kt_v:-}" ]; then printf "%s=%s\\n" "$kt_v" "${!kt_v}" >> "$KT_STATE/env"; fi
            done'

            kt_persist() {
              local state="$1" entry line
              if [ -f "$state/path" ]; then
                local IFS=':'
                for entry in $(cat "$state/path"); do
                  [ -n "$entry" ] && [ -d "$entry" ] || continue
                  case ":$KT_ORIG_PATH:" in *":$entry:"*) continue ;; esac
                  case "$KT_PERSISTED_PATHS" in *":$entry:"*) continue ;; esac
                  KT_PERSISTED_PATHS="$KT_PERSISTED_PATHS$entry:"
                  export PATH="$entry:$PATH"
                  if [ -n "${GITHUB_PATH:-}" ]; then printf '%s\\n' "$entry" >> "$GITHUB_PATH"; fi
                done
                unset IFS
              fi
              if [ -f "$state/env" ]; then
                while IFS= read -r line; do
                  export "${line?}"
                  if [ -n "${GITHUB_ENV:-}" ]; then printf '%s\\n' "$line" >> "$GITHUB_ENV"; fi
                done < "$state/env"
              fi
            }

            kt_run() {
              local id="$1" version="$2" spec="$3" body vars state
              if ! kt_known "$id"; then
                body="$(kt_body '*' passthrough)"
                body="${body//$KT_SPEC_SENTINEL/$spec}"
                vars='MISE_CACHE_DIR'
              elif [ -n "$version" ]; then
                body="$(kt_body "$id" 1)" || kt_die "'$id' does not take a version; use plain '$id'"
                body="${body//$KT_VERSION_SENTINEL/$version}"
                vars="$(kt_cache_vars "$id")"
              else
                body="$(kt_body "$id" 0)"
                vars="$(kt_cache_vars "$id")"
              fi
              state="$(mktemp -d)"
              echo "==> kinhin-toolchain: installing $spec"
              if ! KT_STATE="$state" KT_VARS="$vars" bash -c "$body
            $KT_EPILOGUE"; then
                rm -rf "$state"
                kt_die "installing '$spec' failed"
              fi
              kt_persist "$state"
              rm -rf "$state"
            }

            kt_install() {
              [ "$#" -gt 0 ] || kt_die "install needs at least one id (see: kinhin-toolchain list)"
              local spec_re='^[A-Za-z0-9._+:/@-]+$' version_re='^[A-Za-z0-9._+-]+$'
              local spec id version requested=' ' ordered=() rest=() req
              for spec in "$@"; do
                [[ $spec =~ $spec_re ]] || kt_die "invalid spec '$spec'"
                id="${spec%%@*}"
                [ -n "$id" ] || kt_die "invalid spec '$spec'"
                requested="$requested$id "
                # Runtime providers (node, dotnet, java) go first so dependents find them.
                case " $KT_PROVIDERS " in
                *" $id "*) ordered+=("$spec") ;;
                *) rest+=("$spec") ;;
                esac
              done
              for spec in "$@"; do
                id="${spec%%@*}"
                for req in $(kt_requires "$id"); do
                  case "$requested" in *" $req "*) continue ;; esac
                  command -v "$req" >/dev/null 2>&1 \\
                    || kt_die "'$id' needs $req: add it to the same install (e.g. kinhin-toolchain install $req $spec)"
                done
              done
              for spec in ${ordered[@]+"${ordered[@]}"} ${rest[@]+"${rest[@]}"}; do
                id="${spec%%@*}"
                version=''
                case "$spec" in *@*) version="${spec#*@}" ;; esac
                if kt_known "$id" && [ -n "$version" ]; then
                  [[ $version =~ $version_re ]] || kt_die "invalid version '$version' for '$id'"
                fi
                kt_run "$id" "$version" "$spec"
              done
            }

            case "${1:-}" in
            install)
              shift
              kt_install "$@"
              ;;
            list) kt_list ;;
            -h | --help | help | '') kt_usage ;;
            *)
              kt_usage >&2
              exit 2
              ;;
            esac

            """
    }

    /// One `kt_body` case arm embedding `body` in a quoted heredoc (no expansion).
    private static func helperCase(_ pattern: String, body: String) -> String {
        let quoted = pattern == "*:passthrough" ? "'*:passthrough'" : "'\(pattern)'"
        return """
              \(quoted))
                cat <<'\(toolchainHelperBodyDelimiter)'
            \(body)
            \(toolchainHelperBodyDelimiter)
                ;;
            """
    }
}

// MARK: - Baking

extension RunnerBootstrap {
    /// Writes the `kinhin-toolchain` helper into an image. Gzipped, then
    /// base64-embedded: the script lands verbatim with no shell-escaping, and
    /// stays far below Linux's 128 KB single-argument limit (the container
    /// bake passes the whole script to `bash -lc`). /usr/local/bin needs
    /// root: macOS guests and tart Linux VMs (admin user) go through sudo;
    /// Linux runner containers run as root and skip it.
    static func toolchainHelperInstallScript(
        platform: ToolchainPlatform, mountPath: String, sudo: Bool? = nil
    ) throws -> String {
        let helper = toolchainHelperScript(platform: platform, mountPath: mountPath)
        let encoded: String
        do {
            encoded = try Data(helper.utf8).gzipped().base64EncodedString()
        } catch {
            throw ImageError.provisioningFailed("could not compress the kinhin-toolchain helper: \(error)")
        }
        let needsSudo = sudo ?? (platform == .macOS)
        let sudoPrefix = needsSudo ? "sudo " : ""
        return """
            # kinhin-toolchain: per-job installs (`kinhin-toolchain install node@22 pnpm`)
            \(sudoPrefix)mkdir -p \(dirnameOfHelper)
            echo \(encoded) | base64 --decode | gzip -dc | \(sudoPrefix)tee \(toolchainHelperPath) >/dev/null
            \(sudoPrefix)chmod 755 \(toolchainHelperPath)
            """
    }

    private static var dirnameOfHelper: String {
        (toolchainHelperPath as NSString).deletingLastPathComponent
    }
}

// MARK: - Public surface

extension ToolchainCatalog {
    /// The `kinhin-toolchain` helper exactly as `image prepare` bakes it for
    /// `platform` (for `kinhin toolchains helper`).
    public static func helperScript(for platform: ToolchainPlatform) -> String {
        let mountPath = platform == .macOS ? ToolchainCacheMount.guestPath : ToolchainCacheMount.linuxGuestPath
        return RunnerBootstrap.toolchainHelperScript(platform: platform, mountPath: mountPath)
    }
}
