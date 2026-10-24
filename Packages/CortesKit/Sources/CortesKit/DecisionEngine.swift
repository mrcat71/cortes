import Foundation

public struct RankedTake: Sendable, Hashable, Identifiable {
    public var take: VoiceTake
    public var finalRisk: Int
    public var utility: Double
    public var eligible: Bool
    public var riskReasons: [String]

    public var id: String { take.voiceID }
}

public struct Verdict: Sendable {
    public var read: SituationRead
    /// Display order: most salient first. The recommended take is always included.
    public var ranked: [RankedTake]
    public var recommended: String?
    /// True when no reply is safe enough, or nobody expects one.
    public var sayNothing: Bool
}

/// Deterministic risk rules and scoring on top of the model's self-scores. Rules can only raise risk.
public enum DecisionEngine {
    static let humorStrategies: Set<String> = ["deflect_with_humor", "ironic_agreement", "call_out_absurdity"]
    static let insults = [
        "idiot", "stupid", "dumb", "moron", "wtf", "shit", "fuck", "crap", "damn", "useless",
        "идиот", "дурак", "туп", "бля", "хрен", "хер", "пизд", "ебан", "жоп", "дебил",
    ]
    static let blame = [
        "your fault", "you always", "you never", "not my problem", "not my fault", "you people",
        "твоя вина", "ты всегда", "ты никогда", "не моя проблема", "не моя вина",
    ]
    static let promises = ["i promise", "guarantee", "100%", "definitely by", "обещаю", "гарантирую", "точно сделаю"]
    static let broadcasts = ["@here", "@channel", "@everyone"]

    public static func decide(batch: VoiceBatch, voices: [VoiceDefinition], recentTop: [String] = []) -> Verdict {
        let read = batch.read
        let cap = riskCap(register: read.register)
        var ranked: [RankedTake] = batch.takes.map { take in
            let (finalRisk, reasons) = assessRisk(take, read: read)
            let violations = Double(min(take.issues.count, 3))
            let utility =
                (0.45 * Double(take.help) + 0.30 * Double(take.rel) + 0.25 * Double(9 - finalRisk)) / 9
                - 0.1 * violations
            let eligible = finalRisk <= cap && read.clarity >= 4 && !take.reply.isEmpty
            var allReasons = reasons
            if finalRisk > cap { allReasons.append("risk \(finalRisk) above \(cap) for a \(read.register) chat") }
            return RankedTake(take: take, finalRisk: finalRisk, utility: utility, eligible: eligible, riskReasons: allReasons)
        }
        let recommended = ranked.filter(\.eligible).max { $0.utility < $1.utility }?.id
        let sayNothing = recommended == nil || read.need == "no"

        let volumes = Dictionary(uniqueKeysWithValues: voices.map { ($0.id, $0.volume) })
        func salience(_ r: RankedTake) -> Double {
            var value = 0.6 * Double(r.take.rel) + 0.4 * Double(r.take.fun)
            value += 0.5 * Double((volumes[r.id] ?? 2) - 2)
            if recentTop.suffix(2).allSatisfy({ $0 == r.id }) && recentTop.count >= 2 { value -= 1.5 }
            if r.id == recommended { value += 0.75 }
            return value
        }
        ranked.sort { salience($0) > salience($1) }
        // Show voices with something to say (rel ≥ 3), at least 2, at most 4, and always the recommended one.
        var shown = ranked.filter { $0.take.rel >= 3 || $0.id == recommended }
        if shown.count < 2 { shown = Array(ranked.prefix(2)) }
        if shown.count > 4 { shown = Array(shown.prefix(4)) }
        return Verdict(read: read, ranked: shown, recommended: sayNothing ? nil : recommended, sayNothing: sayNothing)
    }

    public static func riskCap(register: String) -> Int {
        switch register {
        case "professional": 4
        case "casual": 6
        default: 5
        }
    }

    static func assessRisk(_ take: VoiceTake, read: SituationRead) -> (Int, [String]) {
        let reply = take.reply.lowercased()
        var bump = 0
        var reasons: [String] = []
        if humorStrategies.contains(take.strategy), read.tension >= 6, read.register != "casual" {
            bump += 2
            reasons.append("humor under tension \(read.tension) in a \(read.register) chat")
        }
        if insults.contains(where: reply.contains) {
            bump += 3
            reasons.append("insult or profanity")
        }
        if blame.contains(where: reply.contains) {
            bump += 2
            reasons.append("blame phrasing")
        }
        if promises.contains(where: reply.contains) {
            bump += 1
            reasons.append("strong promise")
        }
        if take.reply.contains("!!") || hasCapsRun(take.reply) {
            bump += 1
            reasons.append("shouting")
        }
        if broadcasts.contains(where: reply.contains) {
            bump += 2
            reasons.append("pings the whole channel")
        }
        var risk = min(9, take.risk + bump)
        if containsContactOrSecret(take.reply) {
            risk = max(risk, 7)
            reasons.append("link, contact detail or credential")
        }
        return (risk, reasons)
    }

    static func hasCapsRun(_ text: String) -> Bool {
        var run = 0
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            let letters = word.filter(\.isLetter)
            if letters.count >= 2, letters == letters.uppercased(), letters != letters.lowercased() {
                run += 1
                if run >= 3 { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    static let secretPattern = try! NSRegularExpression(
        pattern: #"(https?://|www\.)|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|\+?\d[\d\s().-]{8,}\d|\b(sk|ghp|xox[abp])[-_][A-Za-z0-9]{8,}|\b[A-Za-z0-9+/]{32,}\b"#,
        options: [.caseInsensitive])

    static func containsContactOrSecret(_ text: String) -> Bool {
        secretPattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
}
