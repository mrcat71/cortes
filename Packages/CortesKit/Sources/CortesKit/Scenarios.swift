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
    public let perspectiveMode: PerspectiveMode

    public init(perspectiveMode: PerspectiveMode = .innerVoices) {
        self.perspectiveMode = perspectiveMode
    }

    public var origin: LLMOrigin { .replay }

    public func complete(
        system: String, turns: [ChatTurn], temperature: Double, maxTokens: Int, schema: Data?
    ) async throws -> LLMResult {
        try await Task.sleep(for: .milliseconds(900))
        let text = perspectiveMode == .business ? Self.businessCanned : Self.canned
        return LLMResult(text: text, latency: 0.9, model: "replay", promptTokens: nil, completionTokens: nil)
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

    public static let businessCanned = """
    {"read":{"to_me":true,"need":"now","tension":7,"register":"professional","clarity":8,"gist":"Public pressure about a slipped deadline"},
     "voices":{
      "developer":{"rel":8,"strategy":"clarify_implementation","thought":"You need to isolate the edge cases before giving another estimate.","reply":"I'll outline the remaining edge cases and technical blockers here by [time], then propose a bounded fix.","help":8,"risk":1,"fun":1},
      "product_owner":{"rel":9,"strategy":"negotiate_scope","thought":"You need an agreed minimum scope, not a deadline for everything.","reply":"Which parts are essential for the launch, and which can follow? Let's agree on the minimum scope before revising the ETA.","help":9,"risk":1,"fun":1},
      "devops":{"rel":8,"strategy":"gate_safe_rollout","thought":"You need staging and a recovery plan before committing to a release.","reply":"Let's confirm staging is available, name the rollout owner, and agree on rollback criteria before releasing.","help":8,"risk":1,"fun":1},
      "qa":{"rel":8,"strategy":"identify_test_gap","thought":"You need evidence that the fix covers the edge cases without regressions.","reply":"Can we list the failing edge cases and required regression checks, then confirm which have passed before calling the fix ready?","help":8,"risk":1,"fun":1}
     }}
    """
}
