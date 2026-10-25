import Foundation
import Testing

@testable import CortesKit

@Suite struct DemoTests {
    @Test func bundledScenariosAreCompleteAndHaveDistinctConversationKeys() {
        let scenarios = Scenario.loadBundled()
        #expect(scenarios.map(\.id) == [
            "launch-war-room", "dm-talk-later", "ru-report", "scope-creep", "friday-release", "dm-credit",
        ])
        #expect(Set(scenarios.map(\.id)).count == scenarios.count)
        let keys = scenarios.map { $0.snapshot(visibleCount: $0.preloaded).key }
        #expect(Set(keys).count == scenarios.count)
        for scenario in scenarios {
            #expect(!scenario.title.isEmpty)
            #expect(!scenario.me.isEmpty)
            #expect(scenario.preloaded > 0 && scenario.preloaded < scenario.lines.count)
            #expect(scenario.lines.contains { $0.from == scenario.me })
            #expect(scenario.lines.contains { $0.from != scenario.me })
            #expect(scenario.lines.allSatisfy { !$0.from.isEmpty && !$0.at.isEmpty && !$0.text.isEmpty })
        }
    }

    @Test(arguments: Scenario.loadBundled())
    func promptsContainOnlyRevealedMessagesAndFocusOnSomeoneElse(scenario: Scenario) throws {
        struct Transcript: Decodable { let messages: [PreparedMessage] }

        for count in scenario.preloaded...scenario.lines.count {
            let snapshot = scenario.snapshot(visibleCount: count)
            let (chat, pseudonymizer) = SuggestionEngine.prepare(snapshot, pseudonymize: true)
            let aliases = try #require(pseudonymizer)
            #expect(chat.messages.count == count)
            #expect(chat.myName == nil)
            for (message, line) in zip(chat.messages, scenario.lines.prefix(count)) {
                #expect(message.from == (line.from == scenario.me ? "ME" : aliases.alias(line.from)))
                #expect(message.text == aliases.scrub(Sanitizer.clean(line.text)))
            }
            let prompt = PromptBuilder.user(chat: chat, mode: "manual")
            let json = try #require(prompt.split(separator: "\n").first)
            let transcript = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
            #expect(transcript.messages == chat.messages)
            let focus = try #require(chat.messages.last { $0.from != "ME" })
            #expect(prompt.contains("Focus: message \(focus.n), written by \(focus.from)."))
            if snapshot.messages.last?.isMe == true {
                #expect(prompt.contains("ME already wrote after it"))
                #expect(TriggerPolicy.attentionScore(snapshot) == 0)
            }
        }
    }
}
