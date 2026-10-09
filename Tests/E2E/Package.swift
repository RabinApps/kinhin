// swift-tools-version:6.2
import PackageDescription

// The end-to-end suite. A separate package on purpose: the root `swift test` (and scripts/check.sh) can never load it,
// so nothing here boots a VM, starts a container or touches the network unless `scripts/e2e.sh` runs it.
// It drives the real `kinhin` binary as a subprocess (black box) against real forges, so it needs no dependency on
// KinhinKit. See docs/e2e-testing.md.
let package = Package(
    name: "kinhin-e2e",
    platforms: [.macOS(.v15)],
    targets: [
        // Sandbox, process helpers, forge fixtures and the fleet config builder.
        .target(name: "E2ESupport", path: "Sources/E2ESupport"),
        .testTarget(name: "E2ETests", dependencies: ["E2ESupport"], path: "Tests/E2ETests"),
    ]
)
