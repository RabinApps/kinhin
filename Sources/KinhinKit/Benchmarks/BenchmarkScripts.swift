import Foundation

/// The shell the suites send into guests. Every script runs under `bash`
/// (macOS guests have 3.2: no associative arrays, no empty-array expansion
/// under `set -u`), reads nothing from the network unless a suite is
/// explicitly network-enabled, and quotes every interpolated value.
enum BenchmarkScripts {
    static func quote(_ value: String) -> String { RunnerBootstrap.shellQuote(value) }

    /// Marker a script prints to report the bytes it moved, when the host
    /// cannot know (the CPU suite's worker count).
    static let bytesMarker = "KINHIN_BENCH_BYTES="
    /// A workload exits with this to say "cannot run here"; its last stdout line is the reason.
    static let skipExitCode: Int32 = 77

    /// Wraps `script` so no command in it can read the rest of the script off stdin. The script reaches the guest as
    /// `bash -s` input, and a child that reads stdin (`brew install` does) silently swallows every line after it:
    /// the install "succeeds" without running its remaining steps. The wrapper writes the script to a temporary
    /// file inside the guest and runs it with stdin closed; the exit status passes through.
    static func isolatingStdin(_ script: String) -> String {
        let payload = Data(script.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        return """
            f=$(mktemp "${TMPDIR:-/tmp}/kinhin-bench.XXXXXX") || exit 1
            base64 --decode > "$f" <<'KINHIN_BENCH_PAYLOAD'
            \(payload)
            KINHIN_BENCH_PAYLOAD
            bash "$f" </dev/null
            rc=$?
            rm -f "$f"
            exit $rc
            """
    }

    /// Strict mode, the tool PATH an SSH shell lacks, and the scratch directory.
    static func prelude(platform: ToolchainPlatform, benchDirectory: String) -> String {
        let path: String
        switch platform {
        case .macOS:
            path = """
                export PATH="$HOME/.local/share/mise/shims:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"
                export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
                # `gem install --user-install` puts executables here, which no login profile adds to PATH.
                if command -v ruby >/dev/null 2>&1; then
                  gem_bin="$(ruby -e 'print Gem.user_dir' 2>/dev/null || true)/bin"
                  export PATH="$gem_bin:$PATH"
                fi
                """
        case .linux:
            path = #"export PATH="$HOME/.local/share/mise/shims:/opt/flutter/bin:/usr/local/bin:$PATH""#
        }
        return """
            set -euo pipefail
            \(path)
            \(benchDirectory)
            mkdir -p "$BENCH"
            cd "$BENCH"
            """
    }

    /// Writes generated files under the current directory; heredocs are quoted, so nothing expands.
    static func writeFiles(_ files: [(path: String, contents: String)], into directory: String) -> String {
        var lines = ["mkdir -p \(quote(directory))"]
        for file in files {
            let path = "\(directory)/\(file.path)"
            lines.append("mkdir -p \(quote((path as NSString).deletingLastPathComponent))")
            lines.append("cat > \(quote(path)) <<'KINHIN_BENCH_EOF'")
            lines.append(file.contents.hasSuffix("\n") ? String(file.contents.dropLast()) : file.contents)
            lines.append("KINHIN_BENCH_EOF")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Casual

    static let tree = "tree"
    static let treeFileBytes = 4_194_304

    static func createTree(megabytes: Int) -> (script: String, bytes: Int) {
        let files = max(megabytes / 4, 1)
        let script = """
            rm -rf tree base.bin && mkdir -p tree
            head -c 1048576 /dev/urandom > base.bin
            i=0
            while [ "$i" -lt \(files) ]; do
              d="tree/d$((i % 16))"; mkdir -p "$d"
              cat base.bin base.bin base.bin base.bin > "$d/f$i.bin"
              i=$((i + 1))
            done
            """
        return (script, files * treeFileBytes)
    }

    static let tarGzip = "rm -f tree.tgz && tar -czf tree.tgz -C tree ."
    static let untar = "rm -rf untar && mkdir untar && tar -xzf tree.tgz -C untar"
    static let hashTree = """
        if command -v shasum >/dev/null 2>&1; then
          find tree -type f -exec shasum -a 256 {} + >/dev/null
        else
          find tree -type f -exec sha256sum {} + >/dev/null
        fi
        """

    static func gitSetup(files: Int) -> String {
        """
        rm -rf repo && mkdir repo && cd repo && git init -q
        line=$(head -c 400 /dev/zero | tr '\\0' x)
        i=0
        while [ "$i" -lt \(files) ]; do
          d="src/m$((i % 25))"; mkdir -p "$d"
          printf 'file %s\\n%s\\n' "$i" "$line" > "$d/f$i.txt"
          i=$((i + 1))
        done
        """
    }

    static let gitCommit = """
        cd repo
        git add -A
        git -c user.name=kinhin-bench -c user.email=bench@kinhin.invalid -c commit.gpgsign=false commit -q -m bench
        """

    static func swiftPackageSetup(files: Int) -> String {
        "rm -rf swiftpkg\n" + writeFiles(BenchmarkScratch.swiftPackageFiles(count: files), into: "swiftpkg")
    }

    static let hasSwift = "command -v swift >/dev/null 2>&1"
    static let swiftBuild = "cd swiftpkg && swift build 2>&1 | tail -n 20"

    // MARK: - Xcode

    static let xcodeProbe = "xcodebuild -version"

    static func xcodePackageSetup(files: Int) -> String {
        "rm -rf xcodepkg dd\n" + writeFiles(BenchmarkScratch.swiftPackageFiles(count: files), into: "xcodepkg")
    }

    /// `xcodebuild` for the generated package; `incremental` touches one source first.
    static func xcodePackageBuild(incremental: Bool) -> String {
        var lines = ["cd xcodepkg"]
        if incremental {
            lines.append("echo '// touched by kinhin bench' >> Sources/BenchLib/Gen0.swift")
        } else {
            lines.append("rm -rf ../dd")
        }
        lines.append(
            "xcodebuild -scheme BenchLib -destination 'generic/platform=macOS' -derivedDataPath ../dd build "
                + "CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | tail -n 20")
        return lines.joined(separator: "\n")
    }

    /// Unpacks a base64 tar stream (the host built it with `tar -C src .`) into `project/`. Extraction stays
    /// inside the directory: the guest's tar strips absolute prefixes and refuses `..` members.
    static func projectUpload(base64Archive: String) -> String {
        """
        rm -rf project dd && mkdir -p project
        base64 --decode <<'KINHIN_BENCH_B64' | tar -x -C project
        \(base64Archive)
        KINHIN_BENCH_B64
        """
    }

    /// Builds the copied project with the first scheme `xcodebuild -list` reports.
    static func projectBuild(incremental: Bool) -> String {
        var lines = [
            "cd project",
            "ws=$(ls -d *.xcworkspace 2>/dev/null | head -n 1 || true)",
            "proj=$(ls -d *.xcodeproj 2>/dev/null | head -n 1 || true)",
            #"xb() { if [ -n "$ws" ]; then xcodebuild -workspace "$ws" "$@"; elif [ -n "$proj" ]; then xcodebuild -project "$proj" "$@"; else xcodebuild -destination 'generic/platform=macOS' "$@"; fi; }"#,
            #"scheme=$(xb -list 2>/dev/null | awk '/Schemes:/{f=1;next} f&&NF{gsub(/^ +/,""); print; exit}')"#,
            #"[ -n "$scheme" ] || { echo "no scheme found"; exit 77; }"#,
        ]
        if incremental {
            lines.append(
                #"f=$(find . -name '*.swift' -not -path './.build/*' -not -path './dd/*' | head -n 1); [ -z "$f" ] || echo '// touched by kinhin bench' >> "$f""#
            )
        } else {
            lines.append("rm -rf ../dd")
        }
        lines.append(
            #"xb -scheme "$scheme" -derivedDataPath ../dd build CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | tail -n 20"#)
        return lines.joined(separator: "\n")
    }

    // MARK: - Large

    static func diskWrite(megabytes: Int) -> String {
        "rm -f blob.bin && dd if=/dev/zero of=blob.bin bs=1048576 count=\(megabytes) 2>/dev/null && sync"
    }

    static let diskRead = "dd if=blob.bin of=/dev/null bs=1048576 2>/dev/null"
    static let hashBlob = """
        if command -v shasum >/dev/null 2>&1; then shasum -a 256 blob.bin >/dev/null; else sha256sum blob.bin >/dev/null; fi
        """

    static func cpuSetup(megabytes: Int) -> String {
        "rm -f rand.bin && head -c \(megabytes * 1_048_576) /dev/urandom > rand.bin"
    }

    static func cpuGzip(megabytes: Int) -> String {
        """
        n=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
        i=0
        while [ "$i" -lt "$n" ]; do gzip -c rand.bin > /dev/null & i=$((i + 1)); done
        wait
        echo "\(bytesMarker)$((n * \(megabytes) * 1048576))"
        """
    }

    /// A shallow clone, restricted to the three URL schemes `BenchmarkOptions.validatedGitURL` allows.
    static func gitClone(url: String) -> String {
        "rm -rf clone && GIT_TERMINAL_PROMPT=0 GIT_ALLOW_PROTOCOL=https:ssh:git git clone -q --depth 1 -- \(quote(url)) clone"
    }

    // MARK: - Teardown

    static let cleanup = #"cd "$HOME" && rm -rf "$BENCH""#
}
