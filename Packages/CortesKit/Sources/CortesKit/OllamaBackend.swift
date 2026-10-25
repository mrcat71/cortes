import Foundation
import os

public struct OllamaConfig: Sendable {
    public static let defaultURL = "http://127.0.0.1:11434"
    public static let defaultModel = "gemma4:12b"

    public var baseURL: String
    public var model: String
    public var contextLength: Int
    public var keepAlive: String
    public var timeout: TimeInterval

    public init(
        baseURL: String = OllamaConfig.defaultURL, model: String = OllamaConfig.defaultModel,
        contextLength: Int = 8192, keepAlive: String = "30m", timeout: TimeInterval = 180
    ) {
        self.baseURL = baseURL
        self.model = model
        self.contextLength = contextLength
        self.keepAlive = keepAlive
        self.timeout = timeout
    }
}

/// Local inference through Ollama's native `/api/chat`: JSON-schema output when available, thinking off,
/// NDJSON streaming. Ollama runs in its own process, so a model crash never takes the app down.
public struct OllamaBackend: LLMBackend {
    public let config: OllamaConfig
    private let session: URLSession
    private let requiresLocalModel: Bool
    private static let log = Logger(subsystem: "io.github.mrcat71.cortes", category: "ollama")

    public init(config: OllamaConfig = OllamaConfig(), session: URLSession = .shared) {
        self.init(config: config, session: session, requiresLocalModel: false)
    }

    init(config: OllamaConfig, session: URLSession, requiresLocalModel: Bool) {
        self.config = config
        self.session = session
        self.requiresLocalModel = requiresLocalModel
    }

    /// Call transcripts must never follow a redirect off this Mac, even from a local model server.
    public static func localOnly(config: OllamaConfig) throws -> OllamaBackend {
        guard CapturePrivacy.isLoopback(config.baseURL) else {
            throw LLMError.unavailable("Call analysis requires a loopback Ollama URL.")
        }
        return OllamaBackend(config: config, session: localSession, requiresLocalModel: true)
    }

    /// Check metadata without sending conversation content. Local aliases can point to cloud models.
    public func verifyLocalModel() async throws {
        try Task.checkCancellation()
        var request = URLRequest(url: try endpoint("api/show"), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": config.model])
        let (data, response) = try await send { try await session.data(for: request) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw describe(status: status, message: ZAIBackend.errorMessage(from: data)) }
        guard let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              ["remote_model", "remote_host"].allSatisfy({ key in
                  metadata[key] == nil || (metadata[key] as? String) == ""
              }),
              let info = metadata["model_info"] as? [String: Any], !info.isEmpty
        else {
            throw LLMError.unavailable("Call analysis requires a downloaded local model, not an Ollama cloud model.")
        }
        try Task.checkCancellation()
    }

    private static let localSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    public var origin: LLMOrigin { .local }
    public var modelName: String { config.model }

    public func complete(
        system: String, turns: [ChatTurn], temperature: Double, maxTokens: Int, schema: Data?
    ) async throws -> LLMResult {
        let started = Date()
        if requiresLocalModel { try await verifyLocalModel() }
        var sendThink = true
        var activeSchema = schema
        while true {
            try Task.checkCancellation()
            let request = try makeRequest(
                system: system, turns: turns, temperature: temperature, maxTokens: maxTokens, schema: activeSchema,
                stream: false, sendThink: sendThink)
            let (data, response) = try await send { try await session.data(for: request) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let message = ZAIBackend.errorMessage(from: data)
                if activeSchema != nil, Self.structuredOutputUnavailable(status: status, message: message) {
                    activeSchema = nil
                    continue
                }
                if status == 400, sendThink, message.lowercased().contains("think") {
                    sendThink = false // older models without a thinking switch reject the flag
                    continue
                }
                throw describe(status: status, message: message)
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = root["message"] as? [String: Any],
                  let content = message["content"] as? String, !content.isEmpty
            else {
                throw LLMError.badResponse(String(decoding: data.prefix(300), as: UTF8.self))
            }
            return LLMResult(
                text: content, latency: Date().timeIntervalSince(started), model: config.model,
                promptTokens: root["prompt_eval_count"] as? Int, completionTokens: root["eval_count"] as? Int)
        }
    }

    public func stream(
        system: String, turns: [ChatTurn], temperature: Double, maxTokens: Int, schema: Data?
    ) -> AsyncThrowingStream<String, Error>? {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if requiresLocalModel { try await verifyLocalModel() }
                    var sendThink = true
                    var activeSchema = schema
                    while true {
                        try Task.checkCancellation()
                        let request = try makeRequest(
                            system: system, turns: turns, temperature: temperature, maxTokens: maxTokens,
                            schema: activeSchema, stream: true, sendThink: sendThink)
                        let (bytes, response) = try await send { try await session.bytes(for: request) }
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        guard status == 200 else {
                            var data = Data()
                            for try await byte in bytes { data.append(byte) }
                            let message = ZAIBackend.errorMessage(from: data)
                            if activeSchema != nil, Self.structuredOutputUnavailable(status: status, message: message) {
                                activeSchema = nil
                                continue
                            }
                            if status == 400, sendThink, message.lowercased().contains("think") {
                                sendThink = false
                                continue
                            }
                            throw describe(status: status, message: message)
                        }
                        var finished = false
                        for try await line in bytes.lines {
                            try Task.checkCancellation()
                            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                            else { throw LLMError.badResponse("invalid Ollama stream chunk") }
                            if let error = object["error"] as? String { throw LLMError.badResponse(error) }
                            if let message = object["message"] as? [String: Any],
                               let content = message["content"] as? String, !content.isEmpty
                            {
                                continuation.yield(content)
                            }
                            if object["done"] as? Bool == true {
                                finished = true
                                break
                            }
                        }
                        try Task.checkCancellation()
                        guard finished else { throw LLMError.badResponse("Ollama stream ended before completion") }
                        break
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Loads the model and caches the system prompt's prefix, so the first real request is fast.
    public func warmUp(system: String) async throws {
        _ = try await complete(
            system: system, turns: [ChatTurn(role: "user", content: "Ready?")], temperature: 0, maxTokens: 1,
            schema: nil)
    }

    /// Frees the model's memory (about 8-10 GB for Gemma 4 12B).
    public func unload() async throws {
        var request = URLRequest(url: try endpoint("api/chat"), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": config.model, "messages": [] as [Any], "keep_alive": 0,
        ])
        _ = try await send { try await session.data(for: request) }
    }

    /// Checks that Ollama answers and the model is downloaded.
    public func status() async -> String {
        do {
            let (data, _) = try await send {
                try await session.data(for: URLRequest(url: try endpoint("api/tags"), timeoutInterval: 5))
            }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let names = (root?["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            let wanted = config.model.contains(":") ? config.model : config.model + ":latest"
            return names.contains(wanted)
                ? "Ollama is running and \(config.model) is downloaded."
                : "Ollama is running, but \(config.model) isn't downloaded. Run: ollama pull \(config.model)"
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Plumbing

    private static func structuredOutputUnavailable(status: Int, message: String) -> Bool {
        guard status == 501, message.lowercased().contains("structured output is unavailable") else { return false }
        // Some Ollama builds lack the grammar library. The prompt requests JSON; ResponseParser validates it.
        log.notice("Ollama structured output is unavailable; retrying without format and validating the response locally")
        return true
    }

    private func endpoint(_ path: String) throws -> URL {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/" + path), url.host() != nil else {
            throw LLMError.unavailable("Invalid Ollama URL: \(config.baseURL)")
        }
        return url
    }

    private func makeRequest(
        system: String, turns: [ChatTurn], temperature: Double, maxTokens: Int, schema: Data?, stream: Bool,
        sendThink: Bool
    ) throws -> URLRequest {
        var fields: [String: Any] = [
            "model": config.model,
            "messages": [["role": "system", "content": system]] + turns.map { ["role": $0.role, "content": $0.content] },
            "stream": stream,
            "keep_alive": config.keepAlive,
            "options": ["temperature": temperature, "num_ctx": config.contextLength, "num_predict": maxTokens],
        ]
        if sendThink { fields["think"] = false }
        var body = try JSONSerialization.data(withJSONObject: fields)
        if let schema {
            // Splice the schema in as raw JSON: re-serializing it through a dictionary would lose key order.
            body = Data("{\"format\":".utf8) + schema + Data(",".utf8) + body.dropFirst()
        }
        var request = URLRequest(url: try endpoint("api/chat"), timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private func send<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as URLError where [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains(error.code) {
            throw LLMError.unavailable("Ollama isn't running at \(config.baseURL). Start it with: brew services start ollama")
        }
    }

    private func describe(status: Int, message: String) -> LLMError {
        if status == 404 || message.lowercased().contains("not found") {
            return .unavailable("\(config.model) isn't downloaded yet. Run: ollama pull \(config.model)")
        }
        Self.log.error("Ollama HTTP \(status): \(message, privacy: .public)")
        return .http(status, message)
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
