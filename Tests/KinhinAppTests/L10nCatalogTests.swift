import XCTest

/// Holds `Sources/kinhin-app/Resources/Localizable.xcstrings` to the app's sources: every user-facing literal
/// has a catalog entry, no entry is stale, plural strings carry plural variations, and no new hard-coded
/// English slips into view or AppKit code. Run through `scripts/l10n-lint.sh`.
///
/// To add or drop catalog entries after editing strings, run `scripts/l10n-lint.sh --sync`
/// (`KINHIN_UPDATE_L10N=1`): it adds missing keys with a generated comment and removes stale ones, and never
/// touches existing translations, variations or comments.
final class L10nCatalogTests: XCTestCase {
    // MARK: - Fixtures

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let sources = root.appendingPathComponent("Sources/kinhin-app")
    private static let catalogURL = sources.appendingPathComponent("Resources/Localizable.xcstrings")

    private var updating: Bool { ProcessInfo.processInfo.environment["KINHIN_UPDATE_L10N"] == "1" }

    private func scanSources() throws -> L10nSourceScanner.Result {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var result = L10nSourceScanner.Result()
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let name = url.path.replacingOccurrences(of: Self.sources.path + "/", with: "")
            let scanned = L10nSourceScanner.scan(source: source, file: name)
            result.literals += scanned.literals
            result.suspicious += scanned.suspicious
        }
        return result
    }

    private func loadCatalog() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.catalogURL)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func save(_ catalog: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (String(decoding: data, as: UTF8.self) + "\n").write(to: Self.catalogURL, atomically: true, encoding: .utf8)
    }

    /// One entry per distinct key, with the best comment seen for it: a hand-written `comment:` wins over the
    /// generated "<call> in <File>" fallback.
    private func expectedEntries(_ literals: [L10nSourceScanner.Literal]) -> [String: String] {
        var entries: [String: (comment: String, handWritten: Bool)] = [:]
        for literal in literals {
            let file = literal.file.split(separator: "/").last!.replacingOccurrences(of: ".swift", with: "")
            let candidate = (
                comment: literal.comment ?? "\(literal.context) in \(file)", handWritten: literal.comment != nil
            )
            if let existing = entries[literal.key], existing.handWritten || !candidate.handWritten { continue }
            entries[literal.key] = candidate
        }
        return entries.mapValues(\.comment)
    }

    // MARK: - Tests

    func testCatalogIsEnglishSourceCatalog() throws {
        let catalog = try loadCatalog()
        XCTAssertEqual(catalog["sourceLanguage"] as? String, "en")
        XCTAssertNotNil(catalog["strings"] as? [String: Any])
    }

    /// Every localized literal has an entry and every entry is still used. `KINHIN_UPDATE_L10N=1` rewrites the
    /// catalog instead of failing.
    func testCatalogMatchesSources() throws {
        var catalog = try loadCatalog()
        var strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        let scanned = try scanSources()
        let expected = expectedEntries(scanned.literals)

        // Compare placeholder-insensitively: `%lld` vs `%@` is a type detail the scanner can only guess.
        func normalized(_ key: String) -> String { L10nSourceScanner.normalized(key) }
        var catalogByNormalized: [String: String] = [:]
        for key in strings.keys { catalogByNormalized[normalized(key)] = key }
        var usedCatalogKeys: Set<String> = []
        var missing: [String] = []
        for key in expected.keys.sorted() {
            if let existing = catalogByNormalized[normalized(key)] {
                usedCatalogKeys.insert(existing)
            } else {
                missing.append(key)
            }
        }
        let stale = strings.keys.filter { !usedCatalogKeys.contains($0) }.sorted()

        if updating {
            for key in missing {
                strings[key] = ["comment": expected[key]!]
            }
            for key in stale { strings[key] = nil }
            catalog["strings"] = strings
            try save(catalog)
            return
        }

        XCTAssertTrue(
            missing.isEmpty,
            "Strings used in code but missing from Localizable.xcstrings (run scripts/l10n-lint.sh --sync):\n"
                + missing.map { "  • \($0)" }.joined(separator: "\n"))
        XCTAssertTrue(
            stale.isEmpty,
            "Catalog entries no code refers to (run scripts/l10n-lint.sh --sync):\n"
                + stale.map { "  • \($0)" }.joined(separator: "\n"))
    }

    /// A catalog entry whose comment says "plural by …" needs English plural variations (or substitutions), so
    /// "1 runners" can't ship. Mark a new plural string by writing "plural by <what is counted>" in its comment.
    func testPluralStringsCarryPluralVariations() throws {
        let strings = try XCTUnwrap(try loadCatalog()["strings"] as? [String: [String: Any]])
        var broken: [String] = []
        for (key, entry) in strings where (entry["comment"] as? String)?.contains("plural by") == true {
            let english = (entry["localizations"] as? [String: Any])?["en"] as? [String: Any]
            let direct = (english?["variations"] as? [String: Any])?["plural"] != nil
            let substituted = (english?["substitutions"] as? [String: Any])?.values.contains {
                (($0 as? [String: Any])?["variations"] as? [String: Any])?["plural"] != nil
            }
            if !direct && substituted != true { broken.append(key) }
        }
        XCTAssertTrue(
            broken.isEmpty,
            "Plural strings without English plural variations in Localizable.xcstrings:\n"
                + broken.sorted().map { "  • \($0)" }.joined(separator: "\n"))
    }

    /// Every entry explains itself to translators.
    func testEveryEntryHasATranslatorComment() throws {
        let strings = try XCTUnwrap(try loadCatalog()["strings"] as? [String: [String: Any]])
        let uncommented = strings.filter { ($0.value["comment"] as? String)?.isEmpty ?? true }.keys.sorted()
        XCTAssertTrue(uncommented.isEmpty, "Catalog entries without a comment: \(uncommented)")
    }

    /// A translation must carry the same placeholders as its key, or `String(format:)` crashes or garbles it.
    func testTranslationsKeepThePlaceholdersOfTheirKey() throws {
        let strings = try XCTUnwrap(try loadCatalog()["strings"] as? [String: [String: Any]])
        func placeholders(_ text: String) -> [String] {
            let regex = try! NSRegularExpression(pattern: "%(\\d+\\$)?(lld|ld|d|@|lf|f)")
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                String(text[Range($0.range, in: text)!]).replacingOccurrences(
                    of: "\\d+\\$", with: "", options: .regularExpression)
            }.sorted()
        }
        var problems: [String] = []
        for (key, entry) in strings {
            guard let localizations = entry["localizations"] as? [String: [String: Any]] else { continue }
            for (language, localization) in localizations where language != "en" {
                var values: [String] = []
                if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
                    values.append(value)
                }
                let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]]
                for form in plural?.values ?? [:].values {
                    if let value = (form["stringUnit"] as? [String: Any])?["value"] as? String { values.append(value) }
                }
                for value in values where Set(placeholders(value)).subtracting(placeholders(key)).isEmpty == false {
                    problems.append("\(language): \(key) → \(value)")
                }
            }
        }
        XCTAssertTrue(
            problems.isEmpty,
            "Translations with placeholders their key doesn't have:\n" + problems.joined(separator: "\n"))
    }

    /// The tripwire for new hard-coded English: a literal that reads like a sentence, in a position that does not
    /// look strings up in the catalog. Fix it by passing it to a localizing API (`Text("…")`,
    /// `String(localized: …, bundle: .l10n, comment: …)`); if it is genuinely not UI text, hand it to a
    /// logging/identifier API or add it to `L10nSourceScanner.allowedProse` with a reason.
    func testNoHardCodedEnglishInViewCode() throws {
        let suspicious = try scanSources().suspicious
        XCTAssertTrue(
            suspicious.isEmpty,
            "String literals that look like user-facing English but are not localized:\n"
                + suspicious.map { "  \($0.file):\($0.line)  \"\($0.text)\"" }.joined(separator: "\n"))
    }
}
