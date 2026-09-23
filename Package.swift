// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "kinhin",
    platforms: [
        .macOS(.v13),
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
        .testTarget(
            name: "KinhinKitTests",
            dependencies: ["KinhinKit"],
            path: "Tests/KinhinKitTests"
        ),
       // Executable targets are importable from tests when their entry
        // point is declared with @main (not a main.swift file).
        .testTarget(
            name: "KinhinCLITests",
            dependencies: ["kinhin"],
            path: "Tests/KinhinCLITests"
        ),
        .testTarget(
            name: "KinhinAppTests",
            dependencies: ["kinhin-app"],
            path: "Tests/KinhinAppTests"
        ),
    ]
)
