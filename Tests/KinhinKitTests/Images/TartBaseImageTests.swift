import XCTest

@testable import KinhinKit

/// The pre-configured tart images (tart.run quick-start "VM images") that
/// back the base-image pickers and `image prepare --linux --from`.
final class TartBaseImageTests: XCTestCase {
    func testCuratedListCoversTheQuickStartImageFamilies() {
        let references = TartBaseImage.curated.map(\.reference)
        // Every macOS series the quick-start lists, in all three flavors.
        for series in ["tahoe", "sequoia", "sonoma"] {
            for flavor in ["base", "vanilla", "xcode"] {
                XCTAssertTrue(
                    references.contains { $0.contains("macos-\(series)-\(flavor)") },
                    "missing the quick-start image macos-\(series)-\(flavor): \(references)")
            }
        }
        // The Linux bases (Fedora included because the docs list it).
        XCTAssertTrue(references.contains("ghcr.io/cirruslabs/ubuntu:latest"))
        XCTAssertTrue(references.contains("ghcr.io/cirruslabs/debian:latest"))
        XCTAssertTrue(references.contains("ghcr.io/cirruslabs/fedora:latest"))
        XCTAssertEqual(Set(references).count, references.count, "references are distinct")
        XCTAssertEqual(Set(TartBaseImage.curated.map(\.title)).count, references.count, "titles are distinct")
    }

    func testShortNameStripsTheRegistryAndTag() {
        XCTAssertEqual(
            TartBaseImage.shortName(for: "ghcr.io/cirruslabs/macos-sequoia-base:latest"), "macos-sequoia-base")
        XCTAssertEqual(TartBaseImage.shortName(for: "ghcr.io/cirruslabs/ubuntu:latest"), "ubuntu")
        XCTAssertEqual(TartBaseImage.shortName(for: "tahoe-base"), "tahoe-base")
    }

    func testResolveSourceKeepsCuratedNamesPinnedToTheirReference() {
        XCTAssertEqual(
            TartBaseImage.resolveSource(preparedName: "macos-sequoia-base"),
            "ghcr.io/cirruslabs/macos-sequoia-base:latest")
        // A hand-picked target (or a --linux VM) starts from the default.
        XCTAssertEqual(TartBaseImage.resolveSource(preparedName: "tahoe-base"), TartBaseImage.defaultReference)
        XCTAssertEqual(TartBaseImage.resolveSource(preparedName: "ubuntu-scratch"), TartBaseImage.defaultReference)
    }

    func testReferenceValidationRejectsArgvHazards() {
        XCTAssertNil(TartBaseImage.problem(with: "ghcr.io/cirruslabs/ubuntu:latest"))
        XCTAssertEqual(TartBaseImage.problem(with: "")?.contains("empty"), true)
        XCTAssertEqual(TartBaseImage.problem(with: "--privileged")?.contains("'-'"), true)
        XCTAssertEqual(TartBaseImage.problem(with: "two words")?.contains("spaces"), true)
    }

    func testKnownSourcesAreTheCuratedListAndTheDefault() {
        XCTAssertTrue(TartBaseImage.isKnownSource(TartBaseImage.defaultReference))
        XCTAssertTrue(TartBaseImage.isKnownSource("ghcr.io/cirruslabs/macos-sequoia-base:latest"))
        // Anything else must exist as a local VM — a renamed registry ref,
        // a tag the registry no longer serves, or a hand-typed typo.
        XCTAssertFalse(TartBaseImage.isKnownSource("ghcr.io/acme/custom:1"))
        XCTAssertFalse(TartBaseImage.isKnownSource("ubuntu-scratch"))
    }

    // MARK: - digest pinning

    private static let digest = "sha256:\(String(repeating: "ab", count: 32))"

    func testDigestPinningRoundTripsThroughTheHelpers() {
        let pinned = "ghcr.io/cirruslabs/macos-sequoia-base:latest@\(Self.digest)"
        XCTAssertTrue(TartBaseImage.isDigestPinned(pinned))
        XCTAssertFalse(TartBaseImage.isDigestPinned("ghcr.io/cirruslabs/macos-sequoia-base:latest"))
        XCTAssertEqual(TartBaseImage.pinnedDigestSuffix(pinned), "ghcr.io/cirruslabs/macos-sequoia-base:latest")
        XCTAssertEqual(TartBaseImage.digestSuffix(pinned), Self.digest)
        XCTAssertNil(TartBaseImage.digestSuffix("ubuntu-scratch"))
    }

    func testPinnedCuratedReferencesStayKnown() {
        let pinned = "ghcr.io/cirruslabs/macos-sequoia-base:latest@\(Self.digest)"
        XCTAssertTrue(TartBaseImage.isKnownSource(pinned), "a digest pin of a curated image is still known")
        // And the pin survives resolveSource — the whole point of pinning.
        XCTAssertEqual(TartBaseImage.resolveSource(preparedName: pinned), pinned)
    }

    func testMutableTagDetection() {
        XCTAssertTrue(TartBaseImage.isMutableTag("ghcr.io/cirruslabs/ubuntu:latest"))
        XCTAssertTrue(TartBaseImage.isMutableTag("ghcr.io/cirruslabs/macos-sequoia-base"), "untagged = latest")
        XCTAssertTrue(TartBaseImage.isMutableTag(TartBaseImage.defaultReference))
        XCTAssertFalse(TartBaseImage.isMutableTag("ghcr.io/cirruslabs/ubuntu:24.04"))
        XCTAssertFalse(TartBaseImage.isMutableTag("ghcr.io/cirruslabs/ubuntu:latest@\(Self.digest)"))
    }

    func testMutableTagWarningNamesTheFixAndStaysSilentOtherwise() {
        // The line the fleet-start log renders for an unpinned base_image.
        let warning = TartBaseImage.mutableTagWarning(for: "ghcr.io/cirruslabs/ubuntu:latest")
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("kinhin image digest") ?? false, warning ?? "")
        XCTAssertTrue(warning?.contains("ghcr.io/cirruslabs/ubuntu:latest") ?? false, warning ?? "")
        // A pinned reference and the absent default are never nagged about.
        XCTAssertNil(TartBaseImage.mutableTagWarning(for: "ghcr.io/cirruslabs/ubuntu:latest@\(Self.digest)"))
        XCTAssertNil(TartBaseImage.mutableTagWarning(for: nil))
        // A specific tag is immutable: no warning either.
        XCTAssertNil(TartBaseImage.mutableTagWarning(for: "ghcr.io/cirruslabs/ubuntu:24.04"))
    }

    func testDigestValidationRejectsMalformedPins() {
        XCTAssertNil(TartBaseImage.digestProblem(in: "ghcr.io/cirruslabs/ubuntu:latest@\(Self.digest)"))
        // Wrong length, non-hex, uppercase, or no hex at all are rejected.
        XCTAssertEqual(
            TartBaseImage.digestProblem(in: "ghcr.io/cirruslabs/ubuntu:latest@sha256:abcd")?.contains("64"), true)
        XCTAssertEqual(
            TartBaseImage.digestProblem(
                in: "ghcr.io/cirruslabs/ubuntu:latest@sha256:\(String(repeating: "g", count: 64))")?
                .contains("hex"), true)
        XCTAssertEqual(
            TartBaseImage.digestProblem(
                in: "ghcr.io/cirruslabs/ubuntu:latest@sha256:\(String(repeating: "A", count: 64))")?
                .contains("hex"), true)
        // problem(with:) carries the digest shape check to config parsing.
        XCTAssertNil(TartBaseImage.problem(with: "ghcr.io/cirruslabs/ubuntu:latest@\(Self.digest)"))
        XCTAssertEqual(
            TartBaseImage.problem(with: "ghcr.io/cirruslabs/ubuntu:latest@sha256:tooshort")?.contains("sha256"), true)
    }
}
