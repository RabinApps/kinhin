// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Orchard",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "orchard", targets: ["orchard"]),
        .executable(name: "orchard-app", targets: ["orchard-app"]),
        .library(name: "OrchardKit", targets: ["OrchardKit"]),
    ],
    dependencies: [
        // YAML parsing for the config file.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        // Shared engine library (no UI).
        .target(
            name: "OrchardKit",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/OrchardKit"
        ),
        // Menu bar application.
        .executableTarget(
            name: "orchard-app",
            dependencies: ["OrchardKit"],
            path: "Sources/orchard-app"
        ),
        // Headless CLI.
        .executableTarget(
            name: "orchard",
            dependencies: ["OrchardKit"],
            path: "Sources/orchard"
        ),
        .testTarget(
            name: "OrchardKitTests",
            dependencies: ["OrchardKit"],
            path: "Tests/OrchardKitTests"
        ),
       // Executable targets are importable from tests when their entry
        // point is declared with @main (not a main.swift file).
        .testTarget(
            name: "OrchardCLITests",
            dependencies: ["orchard"],
            path: "Tests/OrchardCLITests"
        ),
        .testTarget(
            name: "OrchardAppTests",
            dependencies: ["orchard-app"],
            path: "Tests/OrchardAppTests"
        ),
    ]
)
