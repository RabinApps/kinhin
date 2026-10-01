// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "kinhin",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "kinhin", targets: ["kinhin"]),
        .executable(name: "kinhin-app", targets: ["kinhin-app"]),
        .library(name: "KinhinKit", targets: ["KinhinKit"]),
    ],
    dependencies: [
        // YAML parsing for the config file.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        // `swift package --disable-sandbox dev`: runs scripts/dev-run.sh.
        .plugin(
            name: "Dev",
            capability: .command(
                intent: .custom(verb: "dev", description: "Build, sign and run the debug menu bar app"),
                permissions: []
            ),
            path: "Plugins/Dev"
        ),
        // Shared engine library (no UI).
        .target(
            name: "KinhinKit",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/KinhinKit"
        ),
        // Menu bar application.
        .executableTarget(
            name: "kinhin-app",
            dependencies: ["KinhinKit"],
            path: "Sources/kinhin-app",
            // Forge brand marks; scripts/build-app.sh copies the resulting
            // bundle into the .app (see ForgeIcon).
            resources: [.copy("Resources/ForgeIcons")]
        ),
        // Headless CLI.
        .executableTarget(
            name: "kinhin",
            dependencies: ["KinhinKit"],
            path: "Sources/kinhin"
        ),
        // Doubles shared by all three test targets (fake shells, tart, forges).
        // Depends on KinhinKit via @testable, so it is built for testing only;
        // release scripts build products explicitly (`--product`).
        .target(
            name: "KinhinTestSupport",
            dependencies: ["KinhinKit"],
            path: "Tests/KinhinTestSupport"
        ),
        .testTarget(
            name: "KinhinKitTests",
            dependencies: ["KinhinKit", "KinhinTestSupport"],
            path: "Tests/KinhinKitTests"
        ),
       // Executable targets are importable from tests when their entry
        // point is declared with @main (not a main.swift file).
        .testTarget(
            name: "KinhinCLITests",
            dependencies: ["kinhin", "KinhinTestSupport"],
            path: "Tests/KinhinCLITests"
        ),
        .testTarget(
            name: "KinhinAppTests",
            dependencies: ["kinhin-app", "KinhinTestSupport"],
            path: "Tests/KinhinAppTests"
        ),
    ],
    // Strict concurrency on: every mutable field is Mutex-guarded or an
    // immutable Sendable collaborator, so the compiler verifies isolation.
    swiftLanguageModes: [.v6]
)
