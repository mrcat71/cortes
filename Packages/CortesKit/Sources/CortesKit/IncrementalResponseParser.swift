import Foundation

/// Finds complete JSON values at container boundaries. JSONSerialization still parses the values;
/// incomplete strings, scores and voice objects are never exposed as previews.
struct IncrementalResponseParser {
    private var buffer = Data()
    private var closers: [UInt8] = []
    private var inString = false
    private var escaped = false
    private var lastRead: SituationRead?
    private var lastTakes: [VoiceTake] = []

    mutating func append(_ fragment: String, voices: [VoiceDefinition]) -> [VoiceBatch] {
        var updates: [VoiceBatch] = []
        for byte in fragment.utf8 {
            if buffer.isEmpty {
                guard byte == 123 else { continue }
            }
            buffer.append(byte)
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
                continue
            }
            switch byte {
            case 34: inString = true
            case 123: closers.append(125)
            case 91: closers.append(93)
            case 125, 93:
                guard closers.last == byte else { continue }
                closers.removeLast()
                guard closers.count <= 2,
                      let batch = preview(voices: voices),
                      batch.read != lastRead || batch.takes != lastTakes else { continue }
                lastRead = batch.read
                lastTakes = batch.takes
                updates.append(batch)
            default: break
            }
        }
        return updates
    }

    private func preview(voices: [VoiceDefinition]) -> VoiceBatch? {
        let candidate = buffer + Data(closers.reversed())
        guard let object = try? JSONSerialization.jsonObject(with: candidate) as? [String: Any],
              let read = object["read"] as? [String: Any],
              ["to_me", "need", "tension", "register", "clarity", "gist"].allSatisfy({ read[$0] != nil }),
              let takes = object["voices"] as? [String: [String: Any]] else { return nil }
        let complete = voices.filter { voice in
            guard let take = takes[voice.id] else { return false }
            return ["rel", "strategy", "thought", "reply", "help", "risk", "fun"].allSatisfy { take[$0] != nil }
        }
        guard !complete.isEmpty else { return nil }
        return try? ResponseParser.parse(String(decoding: candidate, as: UTF8.self), voices: complete)
    }
}
