import Foundation
import NaturalLanguage

public struct ConversationLanguage: Equatable, Sendable {
    public let code: String
    public static let english = ConversationLanguage(code: "en")

    public init(code: String) { self.code = code }

    public var name: String { Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code }
    public var interfaceCode: String { ["en", "ru", "es"].contains(code) ? code : "en" }
    public var locale: Locale { Locale(identifier: interfaceCode) }

    /// Prefer recent substantive messages; emoji, links and short acknowledgments do not switch the UI.
    public static func detect(in messages: [ChatMessage], fallback: Self = .english) -> Self {
        detect(texts: messages.suffix(8).map(\.text), fallback: fallback)
    }

    public static func detect(texts: [String], fallback: Self = .english) -> Self {
        for text in texts.reversed() {
            let cleaned = text.replacingOccurrences(of: "https?://\\S+|`[^`]*`", with: " ", options: .regularExpression)
            let letters = cleaned.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            guard letters >= 12 else { continue }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(String(cleaned.prefix(2000)))
            guard let language = recognizer.dominantLanguage, language != .undetermined,
                  (recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0) >= (letters < 20 ? 0.9 : 0.65) else { continue }
            return Self(code: language.rawValue)
        }
        return fallback
    }

    /// Short fragments and names are ambiguous. Only reject confidently wrong substantive output.
    func validate(_ batch: VoiceBatch) throws {
        let fields = [("gist", batch.read.gist)] + batch.takes.flatMap {
            [("\($0.voiceID).thought", $0.thought), ("\($0.voiceID).reply", $0.reply)]
        }
        for (field, text) in fields {
            guard text.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 35 else { continue }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            guard let actual = recognizer.dominantLanguage, actual.rawValue != code,
                  (recognizer.languageHypotheses(withMaximum: 1)[actual] ?? 0) >= 0.9 else { continue }
            throw LLMError.invalidOutput("\(field) must use \(name) (\(code)), not \(actual.rawValue)")
        }
    }
}
