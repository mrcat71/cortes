import Foundation

public enum Sensitivity: String, CaseIterable, Sendable, Codable, Identifiable {
    case every
    case low
    case medium
    case high

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .every: "Every message"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    public var threshold: Double {
        switch self {
        case .every: 0
        case .low: 0.6
        case .medium: 0.45
        case .high: 0.3
        }
    }

    /// Auto-mode cooldowns. "Every message" leans on the 1.5 s debounce and revision dedup instead:
    /// local inference makes per-message runs cheap, and cooldowns would silently skip messages.
    public var conversationCooldown: TimeInterval {
        switch self {
        case .every: 0
        case .low, .medium, .high: 20
        }
    }

    public var globalCooldown: TimeInterval {
        switch self {
        case .every: 0
        case .low, .medium, .high: 10
        }
    }
}

/// Deterministic attention score for auto mode (0-1). The manual hotkey bypasses it.
public enum TriggerPolicy {
    static let tensionWords = [
        "asap", "urgent", "again", "why", "disappointed", "blocker", "broken", "broke", "down", "escalat",
        "срочно", "опять", "снова", "почему", "сломал", "упал", "блокер", "разочарован",
    ]
    static let interrogativeOpeners = [
        "can ", "could ", "would ", "will ", "what", "when", "where", "who", "how", "why", "is ", "are ", "do ", "did ",
        "можешь", "можете", "как ", "когда", "где", "кто", "почему", "зачем", "что ",
    ]
    static let acknowledgements: Set<String> = [
        "ok", "okay", "k", "thanks", "thank you", "thx", "ty", "cool", "great", "nice", "👍", "+1", "ок", "окей",
        "спасибо", "спс", "понял", "ага", "да",
    ]

    public static func attentionScore(_ snapshot: ConversationSnapshot) -> Double {
        guard let last = snapshot.messages.last, !last.isMe else { return 0 }
        let text = last.text.lowercased()
        var score = 0.0
        if snapshot.kind == .dm || snapshot.kind == .call || mentionsMe(text, myName: snapshot.myName) { score += 0.4 }
        if text.contains("?") || interrogativeOpeners.contains(where: { text.hasPrefix($0) }) { score += 0.25 }
        if tensionWords.contains(where: text.contains) || last.text.contains("!!") || DecisionEngine.hasCapsRun(last.text) {
            score += 0.2
        }
        let tail = snapshot.messages.suffix(3)
        if tail.count == 3, tail.allSatisfy({ !$0.isMe }) { score += 0.1 }
        let bare = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if acknowledgements.contains(bare) || bare.isEmpty { score -= 0.2 }
        return min(1, max(0, score))
    }

    static func mentionsMe(_ text: String, myName: String?) -> Bool {
        guard let me = myName?.lowercased(), !me.isEmpty else { return false }
        let first = me.split(separator: " ").first.map(String.init) ?? me
        return text.contains("@" + first) || text.contains(me) || text.contains("@" + me)
    }
}
