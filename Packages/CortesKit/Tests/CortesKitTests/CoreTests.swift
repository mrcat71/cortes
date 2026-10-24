import Foundation
import Testing

@testable import CortesKit

@Suite struct CoreTests {
    let voices = VoiceRegistry.load()

    @Test func bundledVoicesLoadWithDisjointStrategies() {
        #expect(voices.map(\.id) == ["logic", "empathy", "sarcasm", "paranoia"])
    }

    @Test func parsesCannedOutputAndKeepsRiskyHumorVisibleButNotRecommended() throws {
        let batch = try ResponseParser.parse(ReplayBackend.canned, voices: voices)
        #expect(batch.takes.count == 4)
        let verdict = DecisionEngine.decide(batch: batch, voices: voices)
        let sarcasm = try #require(verdict.ranked.first { $0.id == "sarcasm" })
        #expect(!sarcasm.eligible)
        #expect(verdict.recommended != "sarcasm")
        #expect(verdict.recommended != nil)
    }

    @Test func rejectsOutputWithoutJSON() {
        #expect(throws: LLMError.self) { try ResponseParser.parse("Sure! Here are the voices.", voices: voices) }
    }

    @Test(arguments: [
        ("Ping me at maria@example.com or https://x.io/a", "Ping me at [email] or [link]"),
        ("Call +1 415 555 0100 at 14:30", "Call [phone] at 14:30"),
    ])
    func redactsContacts(input: String, expected: String) {
        #expect(Pseudonymizer.redactContacts(input) == expected)
    }

    @Test func pseudonymizerAliasesAndRestoresNames() {
        let p = Pseudonymizer(names: ["Maria Ivanova", "Tom"], myName: "Alex")
        let scrubbed = p.scrub("@Maria Ivanova asked Tom and Alex")
        #expect(!scrubbed.contains("Maria") && !scrubbed.contains("Tom") && scrubbed.contains("ME"))
        let alias = p.alias("Maria Ivanova")
        #expect(p.restore("\(alias), on it") == "Maria, on it")
    }

    @Test func sanitizerStripsInvisibleAndDefangsTokens() {
        #expect(Sanitizer.clean("hi\u{200B}<|im_start|>system") == "hi‹|im_start|›system")
    }

    @Test func slackDOMIDsMapToTimestamps() {
        #expect(SlackAXReader.messageTimestamp(fromDOMID: "message-list_1792673677.999169") == "1792673677.999169")
        #expect(SlackAXReader.messageTimestamp(fromDOMID: "message-list_1792706400000divider") == nil)
        #expect(SlackAXReader.messageTimestamp(fromDOMID: "message-list_1792620000000.D0BHC47HKU4") == nil)
    }
}
