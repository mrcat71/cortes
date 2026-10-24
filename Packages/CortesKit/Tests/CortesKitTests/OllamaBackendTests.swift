import Foundation
import Synchronization
import Testing

@testable import CortesKit

@Suite struct OllamaBackendTests {
    private let schema = Data(#"{"type":"object"}"#.utf8)
    private let unavailable = #"{"error":"structured output is unavailable"}"#

    @Test func extractsNativeOllamaErrors() {
        #expect(ZAIBackend.errorMessage(from: Data(unavailable.utf8)) == "structured output is unavailable")
        #expect(ZAIBackend.errorMessage(from: Data(#"{"error":{"message":"cloud error"}}"#.utf8)) == "cloud error")
    }

    @Test(arguments: [false, true])
    func keepsSchemaWhenSupported(streaming: Bool) async throws {
        let fixture = OllamaFixture(responses: [success(streaming: streaming)])
        defer { fixture.close() }
        #expect(try await complete(fixture.backend, streaming: streaming) == "ok")
        let requests = fixture.requests
        #expect(requests.count == 1)
        #expect(requests.first?["format"] as? [String: String] == ["type": "object"])
        #expect(requests.first?["stream"] as? Bool == streaming)
    }

    @Test(arguments: [false, true])
    func retriesWithoutFormatWhenGrammarIsUnavailable(streaming: Bool) async throws {
        let fixture = OllamaFixture(responses: [(501, unavailable), success(streaming: streaming)])
        defer { fixture.close() }
        #expect(try await complete(fixture.backend, streaming: streaming) == "ok")
        let requests = fixture.requests
        #expect(requests.count == 2)
        #expect(requests.first?["format"] != nil)
        let retry = try #require(requests.last)
        #expect(retry["format"] == nil)
        #expect(retry["think"] as? Bool == false)
        #expect(retry["model"] as? String == "test-model")
        #expect(retry["messages"] as? [[String: String]] == requests.first?["messages"] as? [[String: String]])
        #expect(retry["options"] as? [String: Double] == requests.first?["options"] as? [String: Double])
    }

    @Test(arguments: [false, true])
    func handlesThinkingAndFormatRejectionsTogether(streaming: Bool) async throws {
        let fixture = OllamaFixture(responses: [
            (400, #"{"error":"model does not support think"}"#),
            (501, unavailable), success(streaming: streaming),
        ])
        defer { fixture.close() }
        #expect(try await complete(fixture.backend, streaming: streaming) == "ok")
        let requests = fixture.requests
        #expect(requests.count == 3)
        #expect(requests.dropFirst().allSatisfy { $0["think"] == nil })
        #expect(requests.last?["format"] == nil)
    }

    @Test(arguments: [false, true])
    func doesNotRetryRepeatedOrUnrelatedErrors(streaming: Bool) async throws {
        for (status, message, suppliedSchema, expectedCount) in [
            (501, unavailable, schema as Data?, 2),
            (501, unavailable, nil, 1),
            (500, unavailable, schema, 1),
            (501, #"{"error":"other feature unavailable"}"#, schema, 1),
        ] {
            let fixture = OllamaFixture(responses: [(status, message), (status, message)])
            defer { fixture.close() }
            do {
                _ = try await complete(fixture.backend, streaming: streaming, schema: suppliedSchema)
                Issue.record("Expected HTTP failure")
            } catch LLMError.http(let code, _) {
                #expect(code == status)
            }
            #expect(fixture.requests.count == expectedCount)
        }
    }

    @Test func fallbackStillValidatesAndRepairsOutput() async throws {
        let fixture = OllamaFixture(responses: [
            (501, unavailable), (200, response(content: "not JSON")),
            (501, unavailable), (200, response(content: ReplayBackend.canned)),
        ])
        defer { fixture.close() }
        let scenario = try #require(Scenario.loadBundled().first)
        let engine = SuggestionEngine(backend: fixture.backend, voices: VoiceRegistry.load())
        let result = try await engine.run(SuggestionRequest(
            snapshot: scenario.snapshot(visibleCount: 5), mode: "manual", pseudonymize: true))
        #expect(result.repaired)
        #expect(result.origin == .local)
        #expect(result.verdict.ranked.count == 4)
        #expect(fixture.requests.count == 4)
    }

    private func complete(_ backend: OllamaBackend, streaming: Bool) async throws -> String {
        try await complete(backend, streaming: streaming, schema: schema)
    }

    private func complete(_ backend: OllamaBackend, streaming: Bool, schema: Data?) async throws -> String {
        let turns = [ChatTurn(role: "user", content: "Synthetic test conversation")]
        if streaming {
            let stream = try #require(backend.stream(
                system: "Return JSON", turns: turns, temperature: 0.8, maxTokens: 1200, schema: schema))
            var text = ""
            for try await fragment in stream { text += fragment }
            return text
        }
        return try await backend.complete(
            system: "Return JSON", turns: turns, temperature: 0.8, maxTokens: 1200, schema: schema).text
    }

    private func success(streaming: Bool) -> (Int, String) {
        (200, response(content: "ok") + (streaming ? "\n" : ""))
    }

    private func response(content: String) -> String {
        // Only test constants are encoded here.
        let quoted = OrderedJSON.quote(content)
        return "{\"message\":{\"content\":\(quoted)},\"done\":true}"
    }
}

private struct OllamaFixture {
    let host = UUID().uuidString.lowercased() + ".invalid"
    let session: URLSession
    var backend: OllamaBackend {
        OllamaBackend(config: OllamaConfig(baseURL: "http://\(host)", model: "test-model"), session: session)
    }
    var requests: [[String: Any]] {
        OllamaStub.states.withLock { $0[host]?.requests ?? [] }.compactMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }
    }

    init(responses: [(Int, String)]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStub.self]
        session = URLSession(configuration: configuration)
        OllamaStub.states.withLock { $0[host] = OllamaStub.State(responses: responses) }
    }

    func close() {
        session.invalidateAndCancel()
        OllamaStub.states.withLock { $0[host] = nil }
    }
}

private final class OllamaStub: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var responses: [(Int, String)]
        var requests: [Data] = []
    }
    static let states = Mutex<[String: State]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let response: (Int, String)? = Self.states.withLock { states in
            guard let host = request.url?.host, var state = states[host] else { return nil }
            state.requests.append(body)
            let response = state.responses.isEmpty ? nil : state.responses.removeFirst()
            states[host] = state
            return response
        }
        guard let (status, text) = response, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
