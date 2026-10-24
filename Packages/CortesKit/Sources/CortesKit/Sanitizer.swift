import Foundation

/// Cleans untrusted chat text before it reaches the model.
public enum Sanitizer {
    public static func clean(_ input: String, maxLength: Int = 500) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in input.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.value {
            case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF, 0xE0000...0xE007F:
                continue // zero-width, bidi controls, Unicode tag characters
            default:
                scalars.append(scalar)
            }
        }
        // Defang special-token look-alikes such as <|im_start|> or <start_of_turn>.
        var text = String(scalars)
            .replacingOccurrences(of: "<", with: "‹")
            .replacingOccurrences(of: ">", with: "›")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        if text.count > maxLength {
            text = String(text.prefix(maxLength)) + "…"
        }
        return text
    }
}

/// Replaces participant names with aliases and strips contact details before text leaves the Mac.
public struct Pseudonymizer: Sendable {
    private static let aliasPool = [
        "Avery", "Blake", "Casey", "Devon", "Emery", "Finley", "Harper", "Jordan",
        "Kendall", "Logan", "Morgan", "Parker", "Quinn", "Riley", "Sawyer", "Taylor",
    ]

    /// Real full name -> alias.
    public private(set) var aliases: [String: String] = [:]
    private var replacements: [(pattern: String, alias: String)] = []
    private var restorations: [(alias: String, real: String)] = []

    public init(names: [String], myName: String?) {
        let unique = Array(Set(names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
            .sorted()
        let taken = Set(unique.flatMap { $0.lowercased().split(separator: " ").map(String.init) })
        var pool = Self.aliasPool.filter { !taken.contains($0.lowercased()) }.makeIterator()
        var index = 1
        for name in unique {
            let alias = pool.next() ?? "Person\(index)"
            index += 1
            aliases[name] = alias
            replacements.append((name, alias))
            if let first = name.split(separator: " ").first.map(String.init), first.count >= 3, first != name {
                replacements.append((first, alias))
            }
            restorations.append((alias, name.split(separator: " ").first.map(String.init) ?? name))
        }
        if let me = myName?.trimmingCharacters(in: .whitespaces), !me.isEmpty {
            replacements.append((me, "ME"))
            if let first = me.split(separator: " ").first.map(String.init), first.count >= 3, first != me {
                replacements.append((first, "ME"))
            }
        }
        // Longest names first, so "Maria Ivanova" wins over "Maria".
        replacements.sort { $0.pattern.count > $1.pattern.count }
    }

    public func alias(_ name: String) -> String {
        aliases[name.trimmingCharacters(in: .whitespaces)] ?? name
    }

    public func scrub(_ text: String) -> String {
        var result = Self.redactContacts(text)
        for (pattern, alias) in replacements {
            result = Self.replaceWholeWord(pattern, with: alias, in: result)
        }
        return result
    }

    /// Turns aliases in generated text back into real first names.
    public func restore(_ text: String) -> String {
        var result = text
        for (alias, real) in restorations {
            result = Self.replaceWholeWord(alias, with: real, in: result)
        }
        return result
    }

    private static let url = try! NSRegularExpression(pattern: #"(https?://|www\.)\S+"#, options: [.caseInsensitive])
    private static let email = try! NSRegularExpression(pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: [.caseInsensitive])
    private static let phone = try! NSRegularExpression(pattern: #"\+?\d[\d\s().-]{7,}\d"#)

    public static func redactContacts(_ text: String) -> String {
        var result = replace(url, in: text, with: "[link]")
        result = replace(email, in: result, with: "[email]")
        // Only treat long digit runs as phone numbers, so dates and times survive.
        let ns = result as NSString
        var output = result
        for match in phone.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
            let candidate = ns.substring(with: match.range)
            if candidate.filter(\.isNumber).count >= 9, let range = Range(match.range, in: output) {
                output.replaceSubrange(range, with: "[phone]")
            }
        }
        return output
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    static func replaceWholeWord(_ word: String, with replacement: String, in text: String) -> String {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}
