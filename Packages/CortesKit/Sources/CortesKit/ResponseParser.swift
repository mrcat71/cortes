import Foundation

public struct SituationRead: Sendable, Hashable {
    public var toMe: Bool
    public var need: String
    public var tension: Int
    public var register: String
    public var clarity: Int
    public var gist: String
}

public struct VoiceTake: Sendable, Hashable, Identifiable {
    public var voiceID: String
    public var rel: Int
    public var strategy: String
    public var thought: String
    public var reply: String
    public var help: Int
    public var risk: Int
    public var fun: Int
    /// Style violations found by the validator; each costs utility.
    public var issues: [String]

    public var id: String { voiceID }
}

public struct VoiceBatch: Sendable {
    public var read: SituationRead
    public var takes: [VoiceTake]
}

/// Lenient parser plus validator for the model's JSON. z.ai's JSON mode doesn't enforce a schema, so this does.
public enum ResponseParser {
    public static func parse(_ text: String, voices: [VoiceDefinition]) throws -> VoiceBatch {
        guard let object = extractJSONObject(text) else {
            throw LLMError.invalidOutput("no JSON object found")
        }
        let readObject = object["read"] as? [String: Any] ?? [:]
        let read = SituationRead(
            toMe: bool(readObject["to_me"]) ?? true,
            need: oneOf(readObject["need"], ["now", "soon", "no"]) ?? "soon",
            tension: score(readObject["tension"]) ?? 3,
            register: oneOf(readObject["register"], ["professional", "casual", "mixed"]) ?? "mixed",
            clarity: score(readObject["clarity"]) ?? 5,
            gist: (readObject["gist"] as? String).map { trimWords($0, max: 16) } ?? "")

        var rawVoices: [String: [String: Any]] = [:]
        if let dict = object["voices"] as? [String: Any] {
            for (key, value) in dict {
                if let take = value as? [String: Any] { rawVoices[key.lowercased()] = take }
            }
        } else if let list = object["voices"] as? [[String: Any]] {
            for take in list {
                if let id = (take["id"] ?? take["voice"]) as? String { rawVoices[id.lowercased()] = take }
            }
        }

        var takes: [VoiceTake] = []
        var missing: [String] = []
        for voice in voices {
            guard let raw = rawVoices[voice.id] else {
                missing.append(voice.id)
                continue
            }
            var issues: [String] = []
            var strategy = (raw["strategy"] as? String)?.lowercased() ?? ""
            if !voice.strategies.contains(strategy) {
                issues.append("strategy '\(strategy)' isn't one of \(voice.name)'s")
                strategy = voice.strategies.first ?? strategy
            }
            let thought = (raw["thought"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let reply = (raw["reply"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if wordCount(thought) > 26 { issues.append("thought too long") }
            if wordCount(reply) > 40 { issues.append("reply too long") }
            takes.append(
                VoiceTake(
                    voiceID: voice.id,
                    rel: score(raw["rel"]) ?? 5,
                    strategy: strategy,
                    thought: trimWords(thought, max: 30),
                    reply: trimWords(reply, max: 50),
                    help: score(raw["help"]) ?? 5,
                    risk: score(raw["risk"]) ?? 5,
                    fun: score(raw["fun"]) ?? 3,
                    issues: issues))
        }
        let present = takes.filter { !$0.thought.isEmpty }
        if present.count < min(2, voices.count) {
            throw LLMError.invalidOutput("missing voices: \(missing.joined(separator: ", "))")
        }
        return VoiceBatch(read: read, takes: present)
    }

    static func extractJSONObject(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let candidate = String(text[start...end])
        guard let data = candidate.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func score(_ value: Any?) -> Int? {
        let number: Double? =
            switch value {
            case let int as Int: Double(int)
            case let double as Double: double
            case let string as String: Double(string.trimmingCharacters(in: .whitespaces))
            default: nil
            }
        return number.map { min(9, max(0, Int($0.rounded()))) }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool: bool
        case let string as String: ["true", "yes", "1"].contains(string.lowercased())
        case let int as Int: int != 0
        default: nil
        }
    }

    static func oneOf(_ value: Any?, _ allowed: [String]) -> String? {
        guard let string = (value as? String)?.lowercased(), allowed.contains(string) else { return nil }
        return string
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func trimWords(_ text: String, max: Int) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard words.count > max else { return text }
        return words.prefix(max).joined(separator: " ") + "…"
    }
}
