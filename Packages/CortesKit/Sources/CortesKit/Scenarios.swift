import CoreGraphics
import Foundation
import os

/// Synthetic conversations for the Demo Chat window, the CLI and tests.
public struct Scenario: Codable, Sendable, Hashable, Identifiable {
    public struct Line: Codable, Sendable, Hashable {
        public var from: String
        public var at: String
        public var text: String
    }

    public var id: String
    public var title: String
    public var kind: ChatKind
    public var me: String
    /// Lines visible when the scenario starts; the rest arrive with "Next message".
    public var preloaded: Int
    public var lines: [Line]

    public func snapshot(visibleCount: Int, anchor: CGRect? = nil) -> ConversationSnapshot {
        let visible = lines.prefix(max(0, min(visibleCount, lines.count)))
        let messages = visible.enumerated().map { index, line in
            ChatMessage(id: "\(id)-\(index)", author: line.from, text: line.text, time: line.at, isMe: line.from == me)
        }
        return ConversationSnapshot(
            key: ConversationKey(app: "demo", title: title),
            kind: kind,
            messages: messages,
            myName: me,
            anchorFrame: anchor)
    }

    public static func loadBundled() -> [Scenario] {
        let log = Logger(subsystem: "io.github.mrcat71.cortes", category: "scenarios")
        guard let dir = Bundle.module.url(forResource: "Scenarios", withExtension: nil) else {
            log.error("Scenario resources are missing from the bundle")
            return []
        }
        do {
            return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .compactMap { url in
                    do {
                        return try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: url))
                    } catch {
                        log.error("Invalid scenario \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        return nil
                    }
                }
        } catch {
            log.error("Can't list scenarios: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

/// Offline backend that replays a canned answer, for demos without network and for UI work.
public struct ReplayBackend: LLMBackend {
    public init() {}

    public var origin: LLMOrigin { .replay }

    public func complete(
        system: String, turns: [ChatTurn], temperature: Double, maxTokens: Int, schema: Data?
    ) async throws -> LLMResult {
        try await Task.sleep(for: .milliseconds(900))
        return LLMResult(text: Self.canned, latency: 0.9, model: "replay", promptTokens: nil, completionTokens: nil)
    }

    public static let canned = """
    {"read":{"to_me":true,"need":"now","tension":7,"register":"professional","clarity":8,"gist":"Public pressure about a slipped deadline"},
     "voices":{
      "logic":{"rel":7,"strategy":"facts_and_plan","thought":"Two facts matter: what is broken and when it works again. Everything else is noise.","reply":"Two edge cases are still open and staging is down. I'll post the root cause and a realistic ETA here by [time].","help":9,"risk":2,"fun":1},
      "empathy":{"rel":8,"strategy":"acknowledge_and_own","thought":"She isn't angry at you. She's scared of tomorrow. Give her something solid to hold.","reply":"That's on me, I underestimated the edge cases. Sorry for the surprise. The fix is in progress, ETA here by [time].","help":8,"risk":1,"fun":2},
      "sarcasm":{"rel":5,"strategy":"deflect_with_humor","thought":"Ah, Friday. The mythical land where every estimate comes true.","reply":"In my defense, Friday-me was an optimist. Today-me has a fix in progress and an ETA by [time].","help":4,"risk":6,"fun":9},
      "paranoia":{"rel":9,"strategy":"move_to_private","thought":"She asked in public. This isn't a question, it's a record. Logic's explanation becomes evidence.","reply":"Fair question. I'll DM you a short write-up in [minutes]: what broke, the fix, and the new ETA.","help":7,"risk":2,"fun":6}
     }}
    """
}
