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

    @Test(arguments: ["Avery", "avery", "Авэри", "Авери", "Эвери", "Эйвери", "Эйвэри"])
    func restoresRealNamesWhenTheModelTransliteratesAnAlias(spelling: String) {
        let pseudonymizer = Pseudonymizer(names: ["Nikolai Petrov"], myName: "Alex")
        #expect(pseudonymizer.alias("Nikolai Petrov") == "Avery")
        #expect(pseudonymizer.restore("\(spelling) ждёт разрешения от коллеги.") == "Nikolai ждёт разрешения от коллеги.")
        #expect(pseudonymizer.restore("Спроси \(spelling): когда начинаем?") == "Спроси Nikolai: когда начинаем?")
        #expect(pseudonymizer.restore("Not\(spelling)2") == "Not\(spelling)2")
    }

    @Test func aliasesDoNotCollideWithRealNamesInEitherScriptOrTheUsersName() {
        let pseudonymizer = Pseudonymizer(names: ["Блейк Smith", "Maria"], myName: "Avery Jones")
        #expect(pseudonymizer.aliases.values.allSatisfy { $0 != "Avery" && $0 != "Blake" })
        for name in pseudonymizer.aliases.keys {
            #expect(pseudonymizer.restore(pseudonymizer.alias(name)) == name.split(separator: " ").first.map(String.init))
        }
    }

    @Test func restoresSeveralAliasesWithoutChangingUnrelatedWords() {
        let pseudonymizer = Pseudonymizer(names: ["Maria Ivanova", "Tom"], myName: nil)
        #expect(pseudonymizer.restore("Авэри и Блейк; Avery's note; Blakely") == "Maria и Tom; Maria's note; Blakely")
        #expect(PromptBuilder.system(voices: voices).contains("Never translate, transliterate or inflect them"))
    }

    @Test func sanitizerStripsInvisibleAndDefangsTokens() {
        #expect(Sanitizer.clean("hi\u{200B}<|im_start|>system") == "hi‹|im_start|›system")
    }

    @Test func focusIsTheLatestMessageFromSomeoneElse() {
        let chat = PreparedChat(
            app: "slack", kind: .dm, title: "Avery",
            messages: [
                PreparedMessage(n: 1, from: "Avery", at: "10:00", text: "can we talk?"),
                PreparedMessage(n: 2, from: "ME", at: "10:01", text: "sure, when?"),
                PreparedMessage(n: 3, from: "ME", at: "10:05", text: "ping"),
            ],
            myName: nil)
        let line = PromptBuilder.situation(chat: chat, mode: "manual")
        #expect(line.contains("Focus: message 1, written by Avery."))
        #expect(line.contains("ME already wrote after it (messages 2, 3)"))
    }

    @Test(arguments: [
        ("Я еду, а ты? (editado)", "Я еду, а ты?"),
        ("ok (edited)", "ok"),
        ("see (docs)", "see (docs)"),
    ])
    func stripsSlackEditedMarker(input: String, expected: String) {
        #expect(SlackAXReader.stripEditedMarker(input) == expected)
    }

    @Test func slackDOMIDsMapToTimestamps() {
        #expect(SlackAXReader.messageTimestamp(fromDOMID: "message-list_1792673677.999169") == "1792673677.999169")
        #expect(SlackAXReader.messageTimestamp(fromDOMID: "message-list_1792706400000divider") == nil)
        #expect(SlackAXReader.messageTimestamp(fromDOMID: "message-list_1792620000000.D0BHC47HKU4") == nil)
    }

    @Test func schemaIsOrderedValidJSONWithPerVoiceEnums() throws {
        let json = SchemaBuilder.schema(voices: voices)
        let root = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let properties = try #require(root["properties"] as? [String: Any])
        #expect(properties["read"] is [String: Any])
        let voicesSchema = try #require(properties["voices"] as? [String: Any])
        let schemaVoices = try #require(voicesSchema["properties"] as? [String: Any])
        for voice in voices {
            let take = try #require(schemaVoices[voice.id] as? [String: Any])
            let properties = try #require(take["properties"] as? [String: Any])
            #expect(Set(try #require(take["required"] as? [String])) == Set(properties.keys))
            // each voice may only pick its own strategies
            let strategy = try #require(properties["strategy"] as? [String: Any])
            #expect(try #require(strategy["enum"] as? [String]) == voice.strategies)
            for key in ["rel", "help", "risk", "fun"] {
                let score = try #require(properties[key] as? [String: Any])
                #expect(score["minimum"] as? Int == 0 && score["maximum"] as? Int == 9)
            }
        }
        // key order matters for grammar-constrained decoding: scores after the text they judge
        let toMe = try #require(json.range(of: "\"to_me\""))
        let gist = try #require(json.range(of: "\"gist\""))
        let reply = try #require(json.range(of: "\"reply\""))
        let help = try #require(json.range(of: "\"help\""))
        #expect(toMe.lowerBound < gist.lowerBound)
        #expect(reply.lowerBound < help.lowerBound)
    }

    @Test func cannedOutputMatchesTheSchemaVoiceSet() throws {
        let canned = try #require(ResponseParser.extractJSONObject(ReplayBackend.canned))
        let schema = try #require(
            JSONSerialization.jsonObject(with: Data(SchemaBuilder.schema(voices: voices).utf8)) as? [String: Any])
        let cannedVoices = try #require(canned["voices"] as? [String: Any])
        let schemaProperties = try #require(schema["properties"] as? [String: Any])
        let voicesSchema = try #require(schemaProperties["voices"] as? [String: Any])
        let schemaVoices = try #require(voicesSchema["properties"] as? [String: Any])
        #expect(Set(cannedVoices.keys) == Set(schemaVoices.keys))
    }

    @Test func orderedJSONKeepsKeyOrderAndEscapes() {
        let value = OrderedJSON.object([("z", .int(1)), ("a\"b", .string("line\nnext"))])
        #expect(value.serialized == "{\"z\":1,\"a\\\"b\":\"line\\nnext\"}")
    }

    @Test func everyMessageSensitivityPassesTheLowestPossibleScore() {
        #expect(Sensitivity.every.threshold == 0)
        #expect(Sensitivity.every.conversationCooldown == 0 && Sensitivity.every.globalCooldown == 0)
        #expect(Sensitivity.medium.conversationCooldown > 0 && Sensitivity.medium.globalCooldown > 0)
        // a bare acknowledgement in a channel scores 0; "every" must still fire on it
        let snapshot = ConversationSnapshot(
            key: ConversationKey(app: "demo", title: "c"), kind: .channel,
            messages: [ChatMessage(id: "1", author: "A", text: "ok")], myName: "Me", anchorFrame: nil)
        #expect(TriggerPolicy.attentionScore(snapshot) >= Sensitivity.every.threshold)
    }

    @Test func engineHandsTheVoiceSchemaToTheBackend() async throws {
        let scenario = try #require(Scenario.loadBundled().first)
        let spy = SchemaSpyBackend()
        let engine = SuggestionEngine(backend: spy, voices: voices)
        _ = try await engine.run(
            SuggestionRequest(snapshot: scenario.snapshot(visibleCount: 5), mode: "manual", pseudonymize: true))
        let received = try #require(await spy.receivedSchema)
        #expect(String(decoding: received, as: UTF8.self) == SchemaBuilder.schema(voices: voices))
    }
}

/// Records the schema the engine passes down, so the grammar-constrained path is covered without a model.
actor SchemaSpyBackend: LLMBackend {
    nonisolated let origin = LLMOrigin.local
    private(set) var receivedSchema: Data?

    func complete(
        system: String, turns: [ChatTurn], temperature: Double, maxTokens: Int, schema: Data?
    ) async throws -> LLMResult {
        receivedSchema = schema
        return LLMResult(text: ReplayBackend.canned, latency: 0, model: "spy", promptTokens: nil, completionTokens: nil)
    }
}
