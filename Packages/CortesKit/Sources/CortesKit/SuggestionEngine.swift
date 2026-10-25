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
    public var origin: LLMOrigin
}

/// Prompt → model → validation (one repair retry) → alias restore → decision.
public struct SuggestionEngine: Sendable {
    public let backend: any LLMBackend
    public let voices: [VoiceDefinition]
    public let recentTop: [String]
    public let perspectiveMode: PerspectiveMode
    private let log = Logger(subsystem: "io.github.mrcat71.cortes", category: "engine")

    public init(
        backend: any LLMBackend, voices: [VoiceDefinition], recentTop: [String] = [],
        perspectiveMode: PerspectiveMode = .innerVoices
    ) {
        self.backend = backend
        self.voices = voices
        self.recentTop = recentTop
        self.perspectiveMode = perspectiveMode
    }

    /// Previews contain complete voices, not a final recommendation. `nil` clears them before repair.
    public func run(
        _ request: SuggestionRequest, onProgress: (@Sendable (VoiceBatch?) async -> Void)? = nil
    ) async throws -> SuggestionResult {
        let started = Date()
        let (chat, pseudonymizer) = Self.prepare(request.snapshot, pseudonymize: request.pseudonymize)
        let system = PromptBuilder.system(voices: voices, perspectiveMode: perspectiveMode)
        let user = PromptBuilder.user(chat: chat, mode: request.mode)
        // Local decoding is grammar-constrained by this schema; cloud backends ignore it.
        let schema = Data(SchemaBuilder.schema(voices: voices).utf8)

        var turns = [ChatTurn(role: "user", content: user)]
        let first = try await generate(
            system: system, turns: turns, temperature: 0.8, schema: schema,
            pseudonymizer: pseudonymizer, onProgress: onProgress)
        var output = first
        var repaired = false
        var batch: VoiceBatch
        do {
            batch = try ResponseParser.parse(first.text, voices: voices)
        } catch {
            log.notice("Invalid model output, repairing once: \(error.localizedDescription, privacy: .public)")
            try Task.checkCancellation()
            await onProgress?(nil)
            turns.append(ChatTurn(role: "assistant", content: first.text))
            turns.append(ChatTurn(role: "user", content: PromptBuilder.repair(errors: error.localizedDescription)))
            output = try await generate(
                system: system, turns: turns, temperature: 0.3, schema: schema,
                pseudonymizer: pseudonymizer, onProgress: onProgress)
            batch = try ResponseParser.parse(output.text, voices: voices)
            repaired = true
        }

        try Task.checkCancellation()
        batch = Self.restore(batch, using: pseudonymizer)
        let verdict = DecisionEngine.decide(batch: batch, voices: voices, recentTop: recentTop)
        return SuggestionResult(
            key: request.snapshot.key,
            revision: request.snapshot.revision,
            verdict: verdict,
            latency: Date().timeIntervalSince(started),
            model: output.model,
            repaired: repaired,
            origin: backend.origin)
    }

    private func generate(
        system: String, turns: [ChatTurn], temperature: Double, schema: Data,
        pseudonymizer: Pseudonymizer?, onProgress: (@Sendable (VoiceBatch?) async -> Void)?
    ) async throws -> LLMResult {
        guard let onProgress, let stream = backend.stream(
            system: system, turns: turns, temperature: temperature, maxTokens: 1200, schema: schema)
        else {
            return try await backend.complete(
                system: system, turns: turns, temperature: temperature, maxTokens: 1200, schema: schema)
        }
        let started = Date()
        var text = ""
        var parser = IncrementalResponseParser()
        for try await fragment in stream {
            try Task.checkCancellation()
            text += fragment
            for batch in parser.append(fragment, voices: voices) {
                try Task.checkCancellation()
                await onProgress(Self.restore(batch, using: pseudonymizer))
            }
        }
        try Task.checkCancellation()
        return LLMResult(text: text, latency: Date().timeIntervalSince(started), model: backend.modelName)
    }

    private static func restore(_ input: VoiceBatch, using pseudonymizer: Pseudonymizer?) -> VoiceBatch {
        var batch = input
        if let pseudonymizer {
            batch.read.gist = pseudonymizer.restore(batch.read.gist)
            for index in batch.takes.indices {
                batch.takes[index].thought = pseudonymizer.restore(batch.takes[index].thought)
                batch.takes[index].reply = pseudonymizer.restore(batch.takes[index].reply)
            }
        }
        return batch
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
        let others = (snapshot.kind == .context || snapshot.kind == .call) ? [] : kept.filter { !$0.isMe }.map(\.author)
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
