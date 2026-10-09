import Foundation

/// What a toolchain's benchmark does once it is installed: a tiny, fully
/// offline build or run of generated sources, or an explicit reason there is
/// no meaningful offline workload (the row then reports verify only).
enum ToolchainWorkload: Sendable, Equatable {
    case script(name: String, body: String)
    case skip(reason: String)

    var skipReason: String? {
        if case .skip(let reason) = self { return reason }
        return nil
    }
}

/// The per-tool workloads. Every catalog tool and stack has an entry (a test
/// walks the catalog), and no workload fetches anything: sources are
/// generated here, cloud CLIs run local-only flags, nothing reads credentials.
enum ToolchainWorkloads {
    static func workload(for id: String) -> ToolchainWorkload? { table[id] }

    // MARK: - Helpers

    private static func work(_ id: String, _ name: String, _ body: String) -> ToolchainWorkload {
        let directory = BenchmarkScripts.quote("tc-\(id)")
        return .script(name: name, body: "rm -rf \(directory) && mkdir -p \(directory) && cd \(directory)\n\(body)")
    }

    private static func skip(_ reason: String) -> ToolchainWorkload { .skip(reason: reason) }

    /// The loop every language runs, so workloads differ by toolchain and not by algorithm.
    private static let arithmetic = "t = (t * 31 + i) % 1000003"

    private static func requireCompiler(_ names: String = "cc") -> String {
        "command -v \(names) >/dev/null 2>&1 || { echo \"no C compiler (\(names)) in the guest\"; exit 77; }\n"
    }

    // MARK: - Table

    private static let table: [String: ToolchainWorkload] = [
        // Languages and runtimes
        "node": work(
            "node", "node script",
            """
            cat > t.js <<'EOF'
            let t = 0; for (let i = 0; i < 2000000; i++) { \(arithmetic); } console.log(t);
            EOF
            node t.js </dev/null
            """),
        "go": work(
            "go", "go build",
            """
            export GOTOOLCHAIN=local
            printf 'module bench\\n\\ngo 1.21\\n' > go.mod
            cat > main.go <<'EOF'
            package main

            import "fmt"

            func main() {
            \tt := 0
            \tfor i := 0; i < 2000000; i++ { \(arithmetic) }
            \tfmt.Println(t)
            }
            EOF
            go build -o bench . </dev/null && ./bench
            """),
        "rust": work(
            "rust", "cargo build",
            requireCompiler()
                + """
                mkdir -p src
                printf '[package]\\nname = "bench"\\nversion = "0.1.0"\\nedition = "2021"\\n' > Cargo.toml
                cat > src/main.rs <<'EOF'
                fn main() { let mut t: u64 = 0; for i in 0..2_000_000u64 { t = (t * 31 + i) % 1000003; } println!("{}", t); }
                EOF
                cargo build --offline -q </dev/null && ./target/debug/bench
                """),
        "python": work(
            "python", "python script",
            """
            cat > t.py <<'EOF'
            t = 0
            for i in range(2000000):
                \(arithmetic)
            print(t)
            EOF
            python t.py </dev/null
            """),
        "ruby": work(
            "ruby", "ruby script",
            "ruby -e 't = 0; 2_000_000.times { |i| t = (t * 31 + i) % 1000003 }; puts t' </dev/null"),
        "java": work(
            "java", "javac + java",
            """
            cat > Bench.java <<'EOF'
            class Bench { public static void main(String[] a) { long t = 0; for (int i = 0; i < 2000000; i++) { t = (t * 31 + i) % 1000003; } System.out.println(t); } }
            EOF
            javac Bench.java </dev/null && java Bench </dev/null
            """),
        "bun": work(
            "bun", "bun script",
            """
            cat > t.js <<'EOF'
            let t = 0; for (let i = 0; i < 2000000; i++) { \(arithmetic); } console.log(t);
            EOF
            bun t.js </dev/null
            """),
        "deno": work(
            "deno", "deno run",
            """
            cat > t.js <<'EOF'
            let t = 0; for (let i = 0; i < 2000000; i++) { \(arithmetic); } console.log(t);
            EOF
            deno run --no-prompt t.js </dev/null
            """),
        "uv": work("uv", "uv venv", "uv venv .venv </dev/null"),
        "zig": work(
            "zig", "zig run",
            """
            cat > main.zig <<'EOF'
            const std = @import("std");
            pub fn main() void {
                var t: u64 = 0;
                var i: u64 = 0;
                while (i < 2000000) : (i += 1) { t = (t * 31 + i) % 1000003; }
                std.debug.print("{}\\n", .{t});
            }
            EOF
            zig run main.zig </dev/null
            """),
        "erlang": work(
            "erlang", "erl eval",
            """
            erl -noshell -eval 'io:format("~p~n", [lists:foldl(fun(I, T) -> (T * 31 + I) rem 1000003 end, 0, lists:seq(1, 2000000))]), halt().' </dev/null
            """),
        "elixir": work(
            "elixir", "elixir eval",
            "elixir -e 'IO.puts(Enum.reduce(1..2_000_000, 0, fn i, t -> rem(t * 31 + i, 1000003) end))' </dev/null"),
        "kotlin": work(
            "kotlin", "kotlinc + java",
            """
            echo 'fun main() { var t = 0L; for (i in 0 until 2000000) { t = (t * 31 + i) % 1000003 }; println(t) }' > hello.kt
            kotlinc hello.kt -include-runtime -d hello.jar </dev/null 2>&1 | tail -n 3
            java -jar hello.jar </dev/null
            """),
        "scala": skip("Scala 3's launcher resolves its compiler from the network on first use"),
        "clojure": skip("the Clojure CLI resolves org.clojure/clojure from Maven on first run"),
        "dart": work(
            "dart", "dart run",
            """
            cat > t.dart <<'EOF'
            void main() { var t = 0; for (var i = 0; i < 2000000; i++) { t = (t * 31 + i) % 1000003; } print(t); }
            EOF
            dart t.dart </dev/null
            """),
        "swift": work(
            "swift", "swift build",
            BenchmarkScripts.swiftPackageSetup(files: 20) + "\n" + BenchmarkScripts.swiftBuild),
        "lua": work(
            "lua", "lua script",
            "lua -e 'local t = 0 for i = 1, 2000000 do t = (t * 31 + i) % 1000003 end print(t)' </dev/null"),
        "julia": work(
            "julia", "julia eval",
            "julia -e 'println(foldl((t, i) -> (t * 31 + i) % 1000003, 1:2000000; init = 0))' </dev/null"),
        "php": work(
            "php", "php script",
            #"php -r '$t = 0; for ($i = 0; $i < 2000000; $i++) { $t = ($t * 31 + $i) % 1000003; } echo $t, "\n";' </dev/null"#
        ),
        "dotnet": work(
            "dotnet", "dotnet new + build",
            """
            export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
            dotnet new console -o app </dev/null >/dev/null
            cd app && dotnet build -nologo -v q </dev/null
            """),

        // JavaScript tools (need node)
        "pnpm": skip("pnpm resolves its own config dependencies from the registry on first use"),
        "yarn": work(
            "yarn", "yarn init + install",
            "yarn init -y </dev/null >/dev/null && yarn install --offline </dev/null"),
        "playwright": skip("browsers are downloaded on first use; there is no offline workload"),
        "cypress": skip("the Cypress binary is downloaded on first use; there is no offline workload"),
        "netlify-cli": skip("every netlify command talks to the Netlify service"),
        "firebase-tools": skip("every firebase command talks to Google's services"),
        "typescript": work(
            "typescript", "tsc",
            "echo 'const t: number = 1; console.log(t);' > t.ts\ntsc t.ts </dev/null"),
        "eslint": work(
            "eslint", "eslint",
            """
            echo 'const t = 1; console.log(t);' > t.js
            echo 'export default [{ rules: { "no-unused-vars": "error" } }];' > eslint.config.mjs
            eslint t.js </dev/null
            """),
        "prettier": work(
            "prettier", "prettier --write",
            "echo 'const t   =  1;' > t.js\nprettier --write t.js </dev/null"),
        "turbo": skip("turbo needs a configured monorepo workspace and talks to its remote cache"),
        "nx": skip("creating or running an Nx workspace downloads packages"),

        // Build and quality tools
        "cmake": work(
            "cmake", "cmake configure + build",
            requireCompiler("c++")
                + """
                printf 'cmake_minimum_required(VERSION 3.10)\\nproject(bench CXX)\\nadd_executable(bench main.cpp)\\n' > CMakeLists.txt
                echo 'int main() { return 0; }' > main.cpp
                cmake -S . -B build </dev/null >/dev/null && cmake --build build </dev/null >/dev/null
                """),
        "ninja": work(
            "ninja", "ninja build",
            "printf 'rule touch\\n  command = touch $out\\nbuild out.txt: touch\\n' > build.ninja\nninja </dev/null"),
        "maven": work(
            "maven", "mvn validate",
            """
            echo '<project><modelVersion>4.0.0</modelVersion><groupId>bench</groupId><artifactId>bench</artifactId><version>1</version></project>' > pom.xml
            mvn -o -q validate </dev/null
            """),
        "gradle": work(
            "gradle", "gradle help",
            ": > settings.gradle\ngradle --offline --no-daemon -q help </dev/null"),
        "sbt": skip("sbt resolves its launcher and the Scala compiler from the network"),
        "just": work("just", "just", "printf 'default:\\n  @echo hi\\n' > justfile\njust </dev/null"),
        "task": work(
            "task", "task",
            "printf 'version: \"3\"\\ntasks:\\n  default:\\n    cmds:\\n      - echo hi\\n' > Taskfile.yml\ntask </dev/null"
        ),
        "jq": work("jq", "jq", #"echo '{"a":1}' | jq .a"#),
        "yq": work("yq", "yq", "echo 'a: 1' | yq .a"),
        "direnv": work(
            "direnv", "direnv export",
            "echo 'export BENCH_X=1' > .envrc\ndirenv allow . </dev/null\ndirenv export bash </dev/null >/dev/null"),
        "shellcheck": work(
            "shellcheck", "shellcheck",
            "printf '#!/bin/sh\\necho \"$1\"\\n' > t.sh\nshellcheck t.sh </dev/null"),
        "hadolint": work(
            "hadolint", "hadolint",
            "printf 'FROM scratch\\n' > Dockerfile\nhadolint --no-fail Dockerfile </dev/null"),
        "yamllint": work(
            "yamllint", "yamllint",
            "printf -- '---\\na: 1\\n' > t.yml\nyamllint t.yml </dev/null"),
        "composer": work(
            "composer", "composer init + validate",
            "composer init --no-interaction --name=bench/bench -q </dev/null\ncomposer validate --no-check-publish -q </dev/null"
        ),
        "fastlane": skip("fastlane lanes build and ship apps; there is no offline workload"),

        // Cloud and DevOps
        "terraform": work(
            "terraform", "terraform validate",
            """
            printf 'output "x" {\\n  value = 1\\n}\\n' > main.tf
            terraform init -backend=false -input=false </dev/null >/dev/null && terraform validate </dev/null
            """),
        "opentofu": work(
            "opentofu", "tofu validate",
            """
            printf 'output "x" {\\n  value = 1\\n}\\n' > main.tf
            tofu init -backend=false -input=false </dev/null >/dev/null && tofu validate </dev/null
            """),
        "kubectl": work(
            "kubectl", "kubectl dry-run",
            "kubectl create deployment bench --image=bench --dry-run=client -o yaml </dev/null >/dev/null"),
        "helm": work(
            "helm", "helm create + template",
            "helm create chart </dev/null >/dev/null && helm template chart </dev/null >/dev/null"),
        "kustomize": work(
            "kustomize", "kustomize build",
            """
            printf 'resources:\\n  - cm.yaml\\n' > kustomization.yaml
            printf 'apiVersion: v1\\nkind: ConfigMap\\nmetadata:\\n  name: bench\\n' > cm.yaml
            kustomize build . </dev/null >/dev/null
            """),
        "k9s": skip("k9s is a terminal UI for a live cluster"),
        "pulumi": skip("pulumi needs a backend and a project; there is no offline workload"),
        "packer": work(
            "packer", "packer validate",
            "printf 'variable \"x\" {\\n  default = 1\\n}\\n' > t.pkr.hcl\npacker validate -syntax-only t.pkr.hcl </dev/null"
        ),
        "vault": skip("every vault command talks to a Vault server"),
        "gh": skip("every gh command talks to github.com"),
        "awscli": skip("every aws command talks to AWS"),
        "gcloud": skip("every gcloud command talks to Google Cloud"),
        "supabase": skip("supabase commands talk to the Supabase service or a Docker stack"),
        "flyctl": skip("every flyctl command talks to Fly.io"),

        // Stacks
        "flutter": skip("flutter create and build download SDK artifacts on first use"),
        "expo": skip("eas-cli commands talk to Expo's services"),
        "react-native": skip("a React Native build needs an app project and CocoaPods' network index"),
        "vercel": skip("every vercel command talks to Vercel"),
        "cloudflare": skip("wrangler commands talk to Cloudflare"),
    ]
}
