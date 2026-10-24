import Foundation
import Synchronization
import Testing

@testable import CortesKit

@Suite struct StreamingTests {
    private let voices = VoiceRegistry.load()

    @Test func revealsOnlyCompleteVoicesWithoutDuplicateUpdates() throws {
        var parser = IncrementalResponseParser()
        let text = ReplayBackend.canned
        let boundary = try #require(text.range(of: #""empathy""#))
        let first = String(text[..<boundary.lowerBound])
        let updates = first.flatMap { parser.append(String($0), voices: voices) }
        #expect(updates.count == 1)
        #expect(updates.first?.takes.map(\.id) == ["logic"])
        let rest = String(text[boundary.lowerBound...])
        let remaining = rest.flatMap { parser.append(String($0), voices: voices) }
        #expect(remaining.map { $0.takes.count } == [2, 3, 4])
        #expect(parser.append("\n```", voices: voices).isEmpty)
    }

    @Test func handlesMultipleVoicesInOneChunkAndEscapedJSONStrings() throws {
        let thought = #"You see } and {, a "quote", a backslash \, and Привет."#
        let original = try #require(ResponseParser.parse(ReplayBackend.canned, voices: voices).takes.first?.thought)
        let text = ReplayBackend.canned.replacingOccurrences(
            of: OrderedJSON.quote(original), with: OrderedJSON.quote(thought))
        #expect(text.contains(OrderedJSON.quote(thought)))
        var parser = IncrementalResponseParser()
        let updates = text.flatMap { parser.append(String($0), voices: voices) }
        #expect(updates.map { $0.takes.count } == [1, 2, 3, 4])
        let expected = try ResponseParser.parse(text, voices: voices)
        #expect(updates.last?.takes == expected.takes)
        var wholeChunk = IncrementalResponseParser()
        #expect(wholeChunk.append(text, voices: voices).map { $0.takes.count } == [1, 2, 3, 4])
    }

    @Test func doesNotExposeAnIncompleteVoiceOrSituation() {
        for text in [
            #"{"read":{"to_me":true},"voices":{"logic":{"thought":"not ready"}}}"#,
            #"{"read":{"to_me":true,"need":"now","tension":7,"register":"professional","clarity":8,"gist":"A tense chat"},"voices":{"logic":{"rel":8,"strategy":"clarify_facts","thought":"You need facts","reply":"Checking","help":8,"risk":1"#,
        ] {
            var parser = IncrementalResponseParser()
            #expect(parser.append(text, voices: voices).isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1))) func reportsProgressBeforeTheStreamFinishes() async throws {
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        defer { pair.continuation.finish() }
        let events = AsyncStream<VoiceBatch?>.makeStream()
        defer { events.continuation.finish() }
        let engine = SuggestionEngine(backend: ControlledBackend(chunks: pair.stream), voices: voices)
        let request = try request()
        let task = Task {
            try await engine.run(request) { events.continuation.yield($0) }
        }
        defer { task.cancel() }
        let boundary = try #require(ReplayBackend.canned.range(of: #""empathy""#))
        pair.continuation.yield(String(ReplayBackend.canned[..<boundary.lowerBound]))
        var iterator = events.stream.makeAsyncIterator()
        let preview = try #require(await iterator.next())
        #expect(preview?.takes.map(\.id) == ["logic"])
        pair.continuation.yield(String(ReplayBackend.canned[boundary.lowerBound...]))
        pair.continuation.finish()
        let result = try await task.value
        #expect(result.model == "streaming-test")
        #expect(!result.repaired)
        let expected = try await SuggestionEngine(backend: ReplayBackend(), voices: voices).run(request)
        #expect(result.verdict.ranked == expected.verdict.ranked)
        #expect(result.verdict.recommended == expected.verdict.recommended)
    }

    @Test(.timeLimit(.minutes(1))) func cancellationStopsStreamingWithoutRepair() async throws {
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        defer { pair.continuation.finish() }
        let events = AsyncStream<VoiceBatch?>.makeStream()
        defer { events.continuation.finish() }
        let request = try request()
        let engine = SuggestionEngine(backend: ControlledBackend(chunks: pair.stream), voices: voices)
        let task = Task {
            try await engine.run(request) { events.continuation.yield($0) }
        }
        defer { task.cancel() }
        pair.continuation.yield(ReplayBackend.canned)
        var iterator = events.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled generation must not finish or attempt repair")
        } catch is CancellationError {}
    }

    @Test func clearsPreviewsBeforeRepairAndRestoresAliases() async throws {
        let request = try request()
        let (_, pseudonymizer) = SuggestionEngine.prepare(request.snapshot, pseudonymize: true)
        let person = try #require(request.snapshot.messages.first { !$0.isMe }?.author)
        let alias = try #require(pseudonymizer?.alias(person))
        let text = ReplayBackend.canned.replacingOccurrences(of: "She isn't", with: "\(alias) isn't")
        let boundary = try #require(text.range(of: #""empathy""#))
        // A single voice is previewable but insufficient for the final batch, so it must trigger repair.
        let invalid = String(text[..<boundary.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            .dropLast() + "}}"
        let events = Mutex<[VoiceBatch?]>([])
        let backend = ScriptedBackend(first: String(invalid), repaired: text)
        let result = try await SuggestionEngine(backend: backend, voices: voices).run(request) { batch in
            events.withLock { $0.append(batch) }
        }
        #expect(result.repaired)
        let updates = events.withLock { $0 }
        #expect(updates.map { $0?.takes.count } == [1, nil, 1, 2, 3, 4])
        let restored = try #require(pseudonymizer?.restore(alias))
        #expect(updates.last??.takes.contains { $0.thought.contains("\(restored) isn't") } == true)
        #expect(updates.last??.takes.allSatisfy { !$0.thought.contains(alias) } == true)
    }

    @Test func nonStreamingBackendsStillWorkWithProgressCallback() async throws {
        let calls = Mutex(0)
        let result = try await SuggestionEngine(backend: ReplayBackend(), voices: voices).run(try request()) { _ in
            calls.withLock { $0 += 1 }
        }
        #expect(result.origin == .replay)
        #expect(calls.withLock { $0 } == 0)
    }

    private func request() throws -> SuggestionRequest {
        let scenario = try #require(Scenario.loadBundled().first)
        return SuggestionRequest(snapshot: scenario.snapshot(visibleCount: 5), mode: "manual", pseudonymize: true)
    }
}

private struct ControlledBackend: LLMBackend {
    let chunks: AsyncThrowingStream<String, Error>
    var origin: LLMOrigin { .local }
    var modelName: String { "streaming-test" }

    func stream(
        system: String, turns: [ChatTurn], temperature: Double, maxTokens: Int, schema: Data?
    ) -> AsyncThrowingStream<String, Error>? { chunks }

    func complete(
        system: String, turns: [ChatTurn], temperature: Double, maxTokens: Int, schema: Data?
    ) async throws -> LLMResult {
        throw LLMError.badResponse("The streaming test unexpectedly used non-streaming completion")
    }
}

private struct ScriptedBackend: LLMBackend {
    let first: String
    let repaired: String
    var origin: LLMOrigin { .local }

    func stream(
        system: String, turns: [ChatTurn], temperature: Double, maxTokens: Int, schema: Data?
    ) -> AsyncThrowingStream<String, Error>? {
        AsyncThrowingStream { continuation in
            continuation.yield(turns.count == 1 ? first : repaired)
            continuation.finish()
        }
    }

    func complete(
        system: String, turns: [ChatTurn], temperature: Double, maxTokens: Int, schema: Data?
    ) async throws -> LLMResult {
        throw LLMError.badResponse("The streaming test unexpectedly used non-streaming completion")
    }
}
