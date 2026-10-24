import Foundation
import os

public struct VoiceDefinition: Codable, Sendable, Hashable, Identifiable {
    public struct Appearance: Codable, Sendable, Hashable {
        public var color: String
        public var symbol: String
    }

    public var id: String
    public var name: String
    public var order: Int
    public var enabled: Bool
    /// 1-3, like a Disco Elysium skill level: louder voices are shown earlier.
    public var volume: Int
    public var worldview: String
    public var wants: [String]
    public var blindSpot: String
    public var speaksUpWhen: [String]
    public var strategies: [String]
    public var style: String
    public var example: String
    public var ui: Appearance
}

public enum VoiceRegistry {
    private static let log = Logger(subsystem: "io.github.mrcat71.cortes", category: "voices")

    /// User voices live here; a file with the same id as a bundled voice replaces it.
    public static var userDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cortes/Voices", isDirectory: true)
    }

    public static func load() -> [VoiceDefinition] {
        var byID: [String: VoiceDefinition] = [:]
        let bundled = Bundle.module.url(forResource: "Voices", withExtension: nil)
        for dir in [bundled, userDirectory].compactMap({ $0 }) {
            for voice in decodeAll(in: dir) {
                byID[voice.id] = voice
            }
        }
        return validated(Array(byID.values))
    }

    /// Drops voices whose strategies overlap an earlier voice: disagreement is enforced by disjoint strategies.
    public static func validated(_ voices: [VoiceDefinition]) -> [VoiceDefinition] {
        var seen = Set<String>()
        var result: [VoiceDefinition] = []
        for voice in voices.sorted(by: { ($0.order, $0.id) < ($1.order, $1.id) }) {
            let strategies = Set(voice.strategies)
            guard !strategies.isEmpty, strategies.isDisjoint(with: seen) else {
                log.error("Skipping voice \(voice.id, privacy: .public): empty or overlapping strategies")
                continue
            }
            seen.formUnion(strategies)
            result.append(voice)
        }
        return result
    }

    private static func decodeAll(in dir: URL) -> [VoiceDefinition] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
        } catch {
            // A missing user directory is normal; log anything else.
            if (error as NSError).code != NSFileReadNoSuchFileError {
                log.error("Can't list voices in \(dir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return []
        }
        return files.compactMap { url in
            do {
                return try JSONDecoder().decode(VoiceDefinition.self, from: Data(contentsOf: url))
            } catch {
                log.error("Invalid voice file \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }
}
