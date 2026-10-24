import Foundation
import os

public struct SuggestionRequest: Sendable {
    public var snapshot: ConversationSnapshot
    public var mode: String
    public var pseudonymize: Bool

    public init(snapshot: ConversationSnapshot, mode: String, pseudonymize: Bool) {
        self.snapshot = snapshot
        self.mode = mode
        self.pseudonymize = pseudonymize
    }
}

public struct SuggestionResult: Sendable {
    public var key: ConversationKey
    public var revision: String
    public var verdict: Verdict
    public var latency: TimeInterval
    public var model: String
    public var repaired: Bool
    public var cloud: Bool
}

/// Prompt → model → validation (one repair retry) → alias restore → decision.
public struct SuggestionEngine: Sendable {
    public let backend: any LLMBackend
    public let voices: [VoiceDefinition]
    public let recentTop: [String]
    private let log = Logger(subsystem: "io.github.mrcat71.cortes", category: "engine")

    public init(backend: any LLMBackend, voices: [VoiceDefinition], recentTop: [String] = []) {
        self.backend = backend
        self.voices = voices
        self.recentTop = recentTop
    }

    public func run(_ request: SuggestionRequest) async throws -> SuggestionResult {
        let started = Date()
        let (chat, pseudonymizer) = Self.prepare(request.snapshot, pseudonymize: request.pseudonymize)
        let system = PromptBuilder.system(voices: voices)
        let user = PromptBuilder.user(chat: chat, mode: request.mode)

        var turns = [ChatTurn(role: "user", content: user)]
        let first = try await backend.complete(system: system, turns: turns, temperature: 0.8, maxTokens: 1200)
        var output = first
        var repaired = false
        var batch: VoiceBatch
        do {
            batch = try ResponseParser.parse(first.text, voices: voices)
        } catch {
            log.notice("Invalid model output, repairing once: \(error.localizedDescription, privacy: .public)")
            try Task.checkCancellation()
            turns.append(ChatTurn(role: "assistant", content: first.text))
            turns.append(ChatTurn(role: "user", content: PromptBuilder.repair(errors: error.localizedDescription)))
            output = try await backend.complete(system: system, turns: turns, temperature: 0.3, maxTokens: 1200)
            batch = try ResponseParser.parse(output.text, voices: voices)
            repaired = true
        }

        if let pseudonymizer {
            batch.read.gist = pseudonymizer.restore(batch.read.gist)
            for index in batch.takes.indices {
                batch.takes[index].thought = pseudonymizer.restore(batch.takes[index].thought)
                batch.takes[index].reply = pseudonymizer.restore(batch.takes[index].reply)
            }
        }
        let verdict = DecisionEngine.decide(batch: batch, voices: voices, recentTop: recentTop)
        return SuggestionResult(
            key: request.snapshot.key,
            revision: request.snapshot.revision,
            verdict: verdict,
            latency: Date().timeIntervalSince(started),
            model: output.model,
            repaired: repaired,
            cloud: backend.isCloud)
    }

    /// Keeps a recent window (≤ 20 messages, ≤ 6000 characters), sanitizes it and applies aliases.
    public static func prepare(_ snapshot: ConversationSnapshot, pseudonymize: Bool) -> (PreparedChat, Pseudonymizer?) {
        var kept: [ChatMessage] = []
        var budget = 6000
        for message in snapshot.messages.suffix(20).reversed() {
            var cleaned = message
            cleaned.text = Sanitizer.clean(message.text)
            cleaned.author = Sanitizer.clean(message.author, maxLength: 60)
            budget -= cleaned.text.count
            if budget < 0 && !kept.isEmpty { break }
            kept.insert(cleaned, at: 0)
        }
        let others = kept.filter { !$0.isMe }.map(\.author)
        let pseudonymizer = pseudonymize ? Pseudonymizer(names: others, myName: snapshot.myName) : nil
        let messages = kept.enumerated().map { index, message in
            PreparedMessage(
                n: index + 1,
                from: message.isMe ? "ME" : (pseudonymizer?.alias(message.author) ?? message.author),
                at: message.time,
                text: pseudonymizer?.scrub(message.text) ?? message.text)
        }
        let title = Sanitizer.clean(snapshot.key.title, maxLength: 80)
        let chat = PreparedChat(
            app: snapshot.key.app,
            kind: snapshot.kind,
            title: pseudonymizer?.scrub(title) ?? title,
            messages: messages,
            myName: pseudonymize ? nil : snapshot.myName)
        return (chat, pseudonymizer)
    }
}
