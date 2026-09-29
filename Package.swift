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
            path: "Sources/kinhin-app"
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
    // Sources stay in Swift 5 mode for now; the strict-concurrency migration
    // to Swift 6 mode is a separate, dedicated project.
    swiftLanguageModes: [.v5]
)
