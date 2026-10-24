import Foundation
import os

public struct ChatTurn: Sendable, Codable, Hashable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct LLMResult: Sendable {
    public var text: String
    public var latency: TimeInterval
    public var model: String
    public var promptTokens: Int?
    public var completionTokens: Int?
}

/// Where the answers come from; drives the overlay badge and the consent copy.
public enum LLMOrigin: String, Sendable {
    case cloud
    case local
    case replay
}

public enum LLMError: LocalizedError, Sendable {
    case missingKey
    case unavailable(String)
    case http(Int, String)
    case badResponse(String)
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: "No z.ai API key. Add it in Settings → Model."
        case .unavailable(let message): message
        case .http(let code, let message): "The model service returned HTTP \(code): \(message)"
        case .badResponse(let detail): "Unexpected response from the model: \(detail)"
        case .invalidOutput(let detail): "The model's answer didn't match the format: \(detail)"
        }
    }
}

public protocol LLMBackend: Sendable {
    var origin: LLMOrigin { get }
    /// `schema`: a JSON schema (as raw JSON `Data`) the backend may enforce through
    /// grammar-constrained decoding. Backends that can't enforce it ignore it and rely on the validator.
    func complete(
        system: String, turns: [ChatTurn], temperature: Double, maxTokens: Int, schema: Data?
    ) async throws -> LLMResult
}

extension LLMBackend {
    public func complete(
        system: String, turns: [ChatTurn], temperature: Double, maxTokens: Int
    ) async throws -> LLMResult {
        try await complete(system: system, turns: turns, temperature: temperature, maxTokens: maxTokens, schema: nil)
    }
}

public enum ZAIEndpoint {
    public static let general = "https://api.z.ai/api/paas/v4"
    public static let codingPlan = "https://api.z.ai/api/coding/paas/v4"
}

public struct ZAIConfig: Sendable {
    public var baseURL: String
    public var model: String
    public var apiKey: String
    public var disableThinking: Bool
    public var jsonMode: Bool
    public var timeout: TimeInterval

    public init(
        baseURL: String, model: String, apiKey: String, disableThinking: Bool = true, jsonMode: Bool = true,
        timeout: TimeInterval = 45
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.disableThinking = disableThinking
        self.jsonMode = jsonMode
        self.timeout = timeout
    }
}

/// OpenAI-compatible Chat Completions client for z.ai (works with any compatible server).
public actor ZAIBackend: LLMBackend {
    private let config: ZAIConfig
    private let session: URLSession
    private var thinkingParamRejected = false
    private var jsonModeRejected = false
    private let log = Logger(subsystem: "io.github.mrcat71.cortes", category: "zai")

    public init(config: ZAIConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public nonisolated var origin: LLMOrigin { .cloud }

    public func complete(
        system: String, turns: [ChatTurn], temperature: Double, maxTokens: Int, schema: Data?
    ) async throws -> LLMResult {
        guard !config.apiKey.isEmpty else { throw LLMError.missingKey }
        // z.ai's JSON mode doesn't take a schema; ResponseParser enforces the shape instead.
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/chat/completions") else {
            throw LLMError.badResponse("invalid base URL \(config.baseURL)")
        }
        let messages = [["role": "system", "content": system]] + turns.map { ["role": $0.role, "content": $0.content] }

        // Up to two retries, each dropping one optional parameter the model rejected.
        for _ in 0..<3 {
            let sendThinking = config.disableThinking && !thinkingParamRejected
            let sendJSONMode = config.jsonMode && !jsonModeRejected
            var body: [String: Any] = [
                "model": config.model,
                "messages": messages,
                "temperature": temperature,
                // Models that can't skip thinking spend tokens on it, so give them room.
                "max_tokens": sendThinking ? maxTokens : max(maxTokens, 4096),
                "stream": false,
            ]
            if sendJSONMode { body["response_format"] = ["type": "json_object"] }
            if sendThinking { body["thinking"] = ["type": "disabled"] }

            var request = URLRequest(url: url, timeoutInterval: config.timeout)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let started = Date()
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                let message = Self.errorMessage(from: data)
                let lowered = message.lowercased()
                if status == 400, sendThinking, lowered.contains("thinking") {
                    log.notice("Model rejected thinking=disabled; retrying without it")
                    thinkingParamRejected = true
                    continue
                }
                if status == 400, sendJSONMode, lowered.contains("response_format") || lowered.contains("json") {
                    log.notice("Model rejected JSON mode; retrying without it")
                    jsonModeRejected = true
                    continue
                }
                throw LLMError.http(status, message)
            }
            return try Self.parse(data, latency: Date().timeIntervalSince(started), fallbackModel: config.model)
        }
        throw LLMError.badResponse("the model rejected every request variant")
    }

    static func parse(_ data: Data, latency: TimeInterval, fallbackModel: String) throws -> LLMResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any]
        else {
            throw LLMError.badResponse(String(decoding: data.prefix(300), as: UTF8.self))
        }
        let content = (message["content"] as? String) ?? ""
        guard !content.isEmpty else {
            let reason = choices.first?["finish_reason"] as? String ?? "unknown"
            throw LLMError.badResponse("empty content (finish_reason: \(reason))")
        }
        let usage = root["usage"] as? [String: Any]
        return LLMResult(
            text: content,
            latency: latency,
            model: root["model"] as? String ?? fallbackModel,
            promptTokens: usage?["prompt_tokens"] as? Int,
            completionTokens: usage?["completion_tokens"] as? Int)
    }

    static func errorMessage(from data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = root["error"] as? String { return error }
            if let error = root["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = root["message"] as? String { return message }
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }
}
