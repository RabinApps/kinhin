import Foundation

/// Finds the user-facing string literals in the app's Swift sources, so `L10nCatalogTests` can hold the String
/// Catalog (`Sources/kinhin-app/Resources/Localizable.xcstrings`) to them.
///
/// This is a small purpose-built lexer, not a Swift parser. It tracks comments, string literals (with nested
/// interpolations) and a stack of open `(`/`[`/`{` frames, each remembering the callee in front of it, the
/// argument label last seen and the argument position. That is enough to answer "is this literal handed to an
/// API that looks the string up in the catalog?":
///
/// - `String(localized: "…", bundle: .l10n, comment: "…")`, and `LocalizedStringResource = "…"`
/// - the first argument of SwiftUI views and modifiers that take a `LocalizedStringKey` (`Text("…")`,
///   `Button("…")`, `.help("…")`, …) and of this app's own helpers (`HintText`, `statusRow`, …)
/// - named arguments such as `FormCard(title:subtitle:)` and `StatusText(text:)`
///
/// Literals in any other position that read like English prose are reported as `suspicious`; that is the
/// "hard-coded English" tripwire.
struct L10nSourceScanner {
    struct Literal: Equatable {
        let file: String
        let line: Int
        /// The catalog key: interpolations as `%@` / `%lld`, `%` doubled.
        let key: String
        /// The translator comment from `String(localized:comment:)`, when there is one.
        var comment: String?
        /// What kind of call site holds it (`String(localized:)`, `Text`, …); used for generated comments.
        let context: String
    }

    struct Suspicious: Equatable {
        let file: String
        let line: Int
        let text: String
    }

    struct Result {
        var literals: [Literal] = []
        var suspicious: [Suspicious] = []
    }

    // MARK: - Call-site rules

    /// Callees whose first positional argument is a `LocalizedStringKey` / `LocalizedStringResource`.
    static let firstArgumentCallees: Set<String> = [
        "Text", "Button", "Label", "Toggle", "Picker", "HintText", "Section", "SectionHeader", "TextField",
        "SecureField", "LabeledContent", "Menu", "Link", "Stepper", "DisclosureGroup", "IntentDescription",
        "TypeDisplayRepresentation", ".help", ".accessibilityLabel", ".accessibilityValue", ".accessibilityHint",
        ".navigationTitle", ".alert", ".confirmationDialog",
        // this app's own helpers that forward a LocalizedStringKey
        "statusRow", "chipRow", "row", "runtimeRow",
    ]

    /// `callee` → labels whose argument is localized.
    static let labeledArguments: [String: Set<String>] = [
        "FormCard": ["title", "subtitle"], "CollapsibleFormCard": ["title", "subtitle"],
        "StatusText": ["text"], "Parameter": ["title"], "row": ["help"],
        "AppShortcut": ["shortTitle"], "TypeDisplayRepresentation": ["name"],
        "statusRow": ["title", "text"], "chipRow": ["label"],
    ]

    /// Callees whose string arguments are logs, identifiers or other non-UI text.
    static let technicalCallees: Set<String> = [
        ".info", ".warn", ".error", ".debug", "fatalError", "preconditionFailure", "assertionFailure",
        "NSUserInterfaceItemIdentifier", "Selector", ".accessibilityIdentifier", "URL", "Image", "NSImage",
        "UserDefaults", "Bundle", ".id", "print", "XCTAssert",
    ]

    /// Labels whose value is never user-facing.
    static let technicalLabels: Set<String> = [
        "systemName", "systemImage", "systemImageName", "forKey", "identifier", "id", "named", "subdirectory",
        "withExtension", "forResource", "localization", "toggleID", "installID", "prefix", "icon", "verbatim",
        "word", "from", "to", "of",
    ]

    /// Literals that read like prose but are deliberately not in the catalog (reason in the value).
    static let allowedProse: [String: String] = [
        "kinhin": "product name"
    ]

    // MARK: - Scanning

    private struct Frame {
        var callee: String
        var label: String?
        var argumentIndex = 0
        var ternaryDepth = 0
        var lastLiteral: Int?  // index into result.literals of a String(localized:) key awaiting its comment
    }

    static func scan(source: String, file: String) -> Result {
        let s = Array(source.unicodeScalars)
        var result = Result()
        var stack: [Frame] = []
        var line = 1
        var i = 0

        func scalar(_ index: Int) -> Unicode.Scalar? { index >= 0 && index < s.count ? s[index] : nil }
        func isIdentStart(_ c: Unicode.Scalar) -> Bool { c == "_" || (c.properties.isAlphabetic && c.isASCII) }
        func isIdent(_ c: Unicode.Scalar) -> Bool { isIdentStart(c) || (c.value >= 48 && c.value <= 57) }

        /// The identifier (optionally with a leading dot) that ends just before `index`.
        func identifier(before index: Int) -> String {
            var j = index - 1
            while j >= 0, s[j] == " " || s[j] == "\n" || s[j] == "\t" { j -= 1 }
            let end = j + 1
            while j >= 0, isIdent(s[j]) { j -= 1 }
            guard end > j + 1 else { return "" }
            var start = j + 1
            if let c = scalar(j), c == "." { start = j }
            return String(String.UnicodeScalarView(s[start..<end]))
        }

        /// Reads a string literal starting at the opening quote; returns the end index (exclusive) and its pieces.
        func readString(from start: Int) -> (
            end: Int, parts: [(text: String, isInterpolation: Bool, expr: String)], multiline: Bool
        ) {
            if start + 2 < s.count, s[start + 1] == "\"", s[start + 2] == "\"" {
                var j = start + 3
                while j + 2 < s.count, !(s[j] == "\"" && s[j + 1] == "\"" && s[j + 2] == "\"") { j += 1 }
                return (j + 3, [], true)
            }
            var parts: [(String, Bool, String)] = []
            var text = ""
            var j = start + 1
            while j < s.count {
                let c = s[j]
                if c == "\\" {
                    guard let next = scalar(j + 1) else { break }
                    if next == "(" {
                        if !text.isEmpty { parts.append((text, false, "")); text = "" }
                        var depth = 1
                        var k = j + 2
                        var expr = ""
                        while k < s.count, depth > 0 {
                            if s[k] == "\"" {
                                let inner = readString(from: k)
                                expr += String(String.UnicodeScalarView(s[k..<inner.end]))
                                k = inner.end
                                continue
                            }
                            if s[k] == "(" { depth += 1 }
                            if s[k] == ")" {
                                depth -= 1
                                if depth == 0 { break }
                            }
                            expr.unicodeScalars.append(s[k])
                            k += 1
                        }
                        parts.append(("", true, expr))
                        j = k + 1
                        continue
                    }
                    switch next {
                    case "n": text += "\n"
                    case "t": text += "\t"
                    case "\"": text += "\""
                    case "\\": text += "\\"
                    case "u":
                        // \u{1F600}
                        var k = j + 3
                        var hex = ""
                        while k < s.count, s[k] != "}" { hex.unicodeScalars.append(s[k]); k += 1 }
                        if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                            text.unicodeScalars.append(scalar)
                        }
                        j = k + 1
                        continue
                    default: text.unicodeScalars.append(next)
                    }
                    j += 2
                    continue
                }
                if c == "\"" {
                    if !text.isEmpty { parts.append((text, false, "")) }
                    return (j + 1, parts, false)
                }
                text.unicodeScalars.append(c)
                j += 1
            }
            return (j, parts, false)
        }

        /// A catalog key from literal pieces: numeric-looking interpolations are `%lld`, the rest `%@`.
        func makeKey(_ parts: [(text: String, isInterpolation: Bool, expr: String)]) -> String {
            var key = ""
            for part in parts {
                if part.isInterpolation {
                    key += looksNumeric(part.expr) ? "%lld" : "%@"
                } else {
                    key += part.text.replacingOccurrences(of: "%", with: "%%")
                }
            }
            return key
        }

        while i < s.count {
            let c = s[i]
            if c == "\n" { line += 1; i += 1; continue }
            if c == "/", scalar(i + 1) == "/" {
                while i < s.count, s[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", scalar(i + 1) == "*" {
                i += 2
                while i + 1 < s.count, !(s[i] == "*" && s[i + 1] == "/") {
                    if s[i] == "\n" { line += 1 }
                    i += 1
                }
                i += 2
                continue
            }
            if c == "\"" {
                let startLine = line
                let prefixStart = max(0, i - 60)
                let prefix = String(String.UnicodeScalarView(s[prefixStart..<i]))
                let (end, parts, multiline) = readString(from: i)
                for k in i..<min(end, s.count) where s[k] == "\n" { line += 1 }
                i = end
                if multiline { continue }
                let frame = stack.last ?? Frame(callee: "", label: nil)
                let key = makeKey(parts)
                let hasLetters = parts.contains {
                    !$0.isInterpolation && $0.text.range(of: "[A-Za-z]{2}", options: .regularExpression) != nil
                }
                guard hasLetters else { continue }
                // Comment for the String(localized:) key in the same frame.
                if frame.callee == "String", frame.label == "comment" {
                    if let index = stack.last?.lastLiteral, index < result.literals.count {
                        result.literals[index].comment = parts.map(\.text).joined()
                    }
                    continue
                }
                var context: String?
                if frame.callee == "String", frame.label == "localized" {
                    context = "String(localized:)"
                } else if prefix.hasSuffix("LocalizedStringResource = ") {
                    context = "LocalizedStringResource"
                } else if frame.callee == "String" || Self.technicalCallees.contains(frame.callee)
                    || (frame.label.map(Self.technicalLabels.contains) ?? false)
                {
                    context = nil
                } else if let labels = Self.labeledArguments[frame.callee], let label = frame.label,
                    labels.contains(label)
                {
                    context = frame.callee
                } else if Self.firstArgumentCallees.contains(frame.callee), frame.label == nil, frame.argumentIndex == 0
                {
                    context = frame.callee
                }
                if let context {
                    result.literals.append(
                        Literal(file: file, line: startLine, key: key, comment: nil, context: context))
                    if !stack.isEmpty, context == "String(localized:)" {
                        stack[stack.count - 1].lastLiteral = result.literals.count - 1
                    }
                } else if Self.isProse(parts), !Self.technicalCallees.contains(frame.callee),
                    !(frame.label.map(Self.technicalLabels.contains) ?? false), Self.allowedProse[key] == nil,
                    frame.callee != "String"
                {
                    result.suspicious.append(Suspicious(file: file, line: startLine, text: key))
                }
                continue
            }
            switch c {
            case "(":
                let callee = identifier(before: i)
                stack.append(Frame(callee: callee, label: nil))
            case "[", "{":
                stack.append(Frame(callee: "", label: nil))
            case ")", "]", "}":
                if !stack.isEmpty { stack.removeLast() }
            case ",":
                if !stack.isEmpty {
                    stack[stack.count - 1].label = nil
                    stack[stack.count - 1].argumentIndex += 1
                    stack[stack.count - 1].ternaryDepth = 0
                }
            case "?":
                // A ternary operator (not `??`, `?.`, or an optional type `Foo?`).
                let prev = scalar(i - 1)
                let next = scalar(i + 1)
                if prev == " ", next == " ", !stack.isEmpty { stack[stack.count - 1].ternaryDepth += 1 }
                if next == "?" { i += 1 }
            case ":":
                if !stack.isEmpty {
                    if stack[stack.count - 1].ternaryDepth > 0 {
                        stack[stack.count - 1].ternaryDepth -= 1
                    } else {
                        let name = identifier(before: i)
                        if !name.isEmpty, !name.hasPrefix(".") { stack[stack.count - 1].label = name }
                    }
                }
            default: break
            }
            i += 1
        }
        return result
    }

    // MARK: - Heuristics

    /// Names of values interpolated into UI strings that are numbers (their catalog placeholder is `%lld`).
    /// Add a name here when a new numeric interpolation is introduced; the check is only about the key's
    /// placeholder, so a miss just leaves a `%@` that translators can't pluralize.
    static let numericNames: Set<String> = [
        "count", "cap", "n", "logicalCores", "memoryGB", "freeDiskGB", "activeCount", "capacityCap", "queueDepth",
        "maxConcurrent", "jobSlots", "macOSDiskGB", "failed", "size", "instanceCount", "busyCount",
    ]

    /// Whether an interpolated expression is a number (so its catalog placeholder is `%lld`).
    static func looksNumeric(_ expr: String) -> Bool {
        let e = expr.trimmingCharacters(in: .whitespaces)
        if e.hasPrefix("Int(") || e.range(of: "[+-] ?1$", options: .regularExpression) != nil
            || e.range(of: "\\.count( |$)", options: .regularExpression) != nil
        {
            return true
        }
        let last = e.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).last.map(String.init) ?? e
        return numericNames.contains(last)
    }

    /// A literal that reads like English prose: several letters, at least two words.
    static func isProse(_ parts: [(text: String, isInterpolation: Bool, expr: String)]) -> Bool {
        let text = parts.filter { !$0.isInterpolation }.map(\.text).joined(separator: "x")
        let words = text.split(separator: " ").filter {
            $0.range(of: "[A-Za-z]{2,}", options: .regularExpression) != nil
        }
        guard words.count >= 2 else { return false }
        // App Shortcut phrases are localized through AppShortcuts.strings, not this catalog.
        if parts.contains(where: { $0.isInterpolation && $0.expr == ".applicationName" }) { return false }
        if text.contains("://") || text.hasPrefix("/") || text.hasPrefix("~") { return false }
        return text.range(of: "^[A-Z][a-z]", options: .regularExpression) != nil
    }

    /// The same key with every printf specifier collapsed, so `%lld` and `%@` compare equal.
    static func normalized(_ key: String) -> String {
        key.replacingOccurrences(of: "%(\\d+\\$)?(lld|ld|d|@|lf|f)", with: "%@", options: .regularExpression)
    }
}
