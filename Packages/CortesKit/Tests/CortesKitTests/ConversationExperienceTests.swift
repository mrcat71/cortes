import CoreGraphics
import Foundation
import Testing

@testable import CortesKit

@Suite struct ConversationExperienceTests {
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let messages = CGRect(x: 300, y: 250, width: 700, height: 650)
    private let composer = CGRect(x: 300, y: 120, width: 700, height: 100)

    @Test func docksNearComposerWithoutCoveringMessagesOrDraft() throws {
        let frame = try #require(OverlayPlacement.frame(
            size: CGSize(width: 380, height: 600), visibleFrame: screen, anchor: messages,
            composer: composer, protectedFrames: [messages]))
        #expect(!frame.intersects(messages))
        #expect(!frame.intersects(composer))
        #expect(screen.contains(frame))
        #expect(abs(frame.minY - composer.minY) < 20)
        #expect(frame.minX > composer.maxX)
    }

    @Test func resizesForFreeSpaceInsteadOfCoveringEitherThreadOrChannel() throws {
        let channel = CGRect(x: 280, y: 220, width: 720, height: 730)
        let thread = CGRect(x: 1000, y: 220, width: 580, height: 730)
        let draft = CGRect(x: 1000, y: 80, width: 580, height: 100)
        let frame = try #require(OverlayPlacement.frame(
            size: CGSize(width: 380, height: 850), visibleFrame: screen, anchor: thread,
            composer: draft, protectedFrames: [channel, thread]))
        #expect(!frame.intersects(channel) && !frame.intersects(thread) && !frame.intersects(draft))
        #expect(screen.contains(frame))
        #expect(frame.height < 850 || frame.width < 380)
    }

    @Test func prefersTheFullResultOverAShortRegionNearTheComposer() throws {
        let pane = CGRect(x: 450, y: 260, width: 1140, height: 730)
        let draft = CGRect(x: 450, y: 130, width: 1140, height: 100)
        let frame = try #require(OverlayPlacement.frame(
            size: CGSize(width: 380, height: 850), visibleFrame: screen, anchor: pane,
            composer: draft, protectedFrames: [pane]))
        #expect(frame.size == CGSize(width: 380, height: 850))
        #expect(frame.maxX < pane.minX)
        #expect(!frame.intersects(pane) && !frame.intersects(draft))
    }

    @Test func oversizedResultStaysOnScreenAndUsesTheAvailableHeight() throws {
        let frame = try #require(OverlayPlacement.frame(
            size: CGSize(width: 380, height: 1800), visibleFrame: screen, anchor: nil,
            composer: nil, protectedFrames: []))
        #expect(frame.width == 380)
        #expect(frame.height == screen.height - 16)
        #expect(screen.contains(frame))
    }

    @Test(arguments: [CGRect(x: -1920, y: 0, width: 1920, height: 1080), CGRect(x: 0, y: 1000, width: 1400, height: 900)])
    func placementSupportsNonPrimaryDisplays(visible: CGRect) throws {
        let pane = CGRect(x: visible.minX + 100, y: visible.minY + 200, width: 800, height: 600)
        let draft = CGRect(x: pane.minX, y: pane.minY - 130, width: pane.width, height: 100)
        let frame = try #require(OverlayPlacement.frame(
            size: CGSize(width: 380, height: 600), visibleFrame: visible, anchor: pane,
            composer: draft, protectedFrames: [pane]))
        #expect(visible.contains(frame))
        #expect(!frame.intersects(pane) && !frame.intersects(draft))
    }

    @Test func refusesToCoverTextWhenNoSafeRegionExists() {
        #expect(OverlayPlacement.frame(size: CGSize(width: 380, height: 600), visibleFrame: screen,
            anchor: screen, composer: nil, protectedFrames: [screen]) == nil)
    }

    @Test func missingAnchorDoesNotReusePreviousConversationGeometry() throws {
        let frame = try #require(OverlayPlacement.frame(size: CGSize(width: 380, height: 300),
            visibleFrame: screen, anchor: nil, composer: nil, protectedFrames: []))
        #expect(frame.maxX == screen.maxX - 8)
        #expect(frame.maxY == screen.maxY - 8)
    }

    @Test func threadSelectionFollowsFocusedComposer() {
        let frames: [CGRect?] = [messages, CGRect(x: 1000, y: 250, width: 500, height: 650)]
        #expect(SlackAXReader.targetIndex(frames: frames, threads: [false, true], focus: nil, focusedIndex: 0) == 0)
        #expect(SlackAXReader.targetIndex(frames: frames, threads: [false, true], focus: nil, focusedIndex: 1) == 1)
        #expect(SlackAXReader.targetIndex(frames: frames, threads: [false, true], focus: nil, focusedIndex: nil) == 1)
        #expect(SlackAXReader.targetIndex(frames: frames, threads: [false, true],
            focus: CGRect(x: 450, y: 400, width: 20, height: 20), focusedIndex: nil) == 0)
    }

    @Test func threadConsentAndCooldownAreSeparateFromChannelAndOtherThreads() throws {
        let channel = ConversationKey(app: "slack", title: "team")
        let thread = ConversationKey(app: "slack", title: "team", threadID: "1792673677.999169")
        let other = ConversationKey(app: "slack", title: "team", threadID: "1792673678.000001")
        #expect(Set([channel.id, thread.id, other.id]).count == 3)
        #expect(channel.id == "slack:team")
        #expect(try JSONDecoder().decode(ConversationKey.self, from: JSONEncoder().encode(thread)) == thread)
        let legacy = Data(#"{"app":"slack","title":"team"}"#.utf8)
        #expect(try JSONDecoder().decode(ConversationKey.self, from: legacy) == channel)
    }

    @Test func longThreadsRetainTheirParentAlongsideRecentReplies() {
        let messages = (0..<45).map { ChatMessage(id: String($0), author: "Ana", text: "Message \($0): " + String(repeating: "x", count: 800)) }
        let captured = SlackAXReader.recentMessages(messages, limit: 30, includeParent: true)
        #expect(captured.count == 30 && captured.first?.id == "0" && captured.last?.id == "44")
        let snapshot = ConversationSnapshot(key: .init(app: "slack", title: "team", threadID: "0"), kind: .channel,
            messages: captured, myName: nil, anchorFrame: nil)
        let (prepared, _) = SuggestionEngine.prepare(snapshot, pseudonymize: false)
        #expect(prepared.messages.first?.text.hasPrefix("Message 0:") == true)
        #expect(prepared.messages.last?.text.hasPrefix("Message 44:") == true)
        #expect(prepared.messages.count <= 20)
        #expect(prepared.messages.reduce(0) { $0 + $1.text.count } <= 6000)
    }

    @Test(arguments: [
        ("Please check the deployment before we release this change to our customers.", "en"),
        ("Пожалуйста, проверь развертывание перед выпуском этого изменения для наших клиентов.", "ru"),
        ("Por favor, revisa el despliegue antes de publicar este cambio para nuestros clientes.", "es"),
        ("Bitte prüfe die Bereitstellung, bevor wir diese Änderung für unsere Kunden veröffentlichen.", "de"),
    ])
    func detectsConversationLanguageNotSystemLocale(text: String, code: String) {
        #expect(ConversationLanguage.detect(texts: [text]).code == code)
    }

    @Test func recentSubstantiveMessageWinsOverHistoryAndShortAcknowledgments() {
        let old = "Please check the deployment before we release this change to our customers."
        let latest = "Пожалуйста, проверь развертывание перед выпуском этого изменения для наших клиентов."
        #expect(ConversationLanguage.detect(texts: [old, latest, "OK 👍"]).code == "ru")
        #expect(ConversationLanguage.detect(texts: ["👍", "https://example.com/path"], fallback: .init(code: "es")).code == "es")
        #expect(ConversationLanguage.detect(texts: []).code == "en")
        #expect(ConversationLanguage(code: "de").interfaceCode == "en")
        #expect(ConversationLanguage.detect(texts: ["Давай обсудим завтра."]).code == "ru")
    }

    @Test func promptsSpecifyLanguageAndThreadScopeWithoutChangingSchemaIdentifiers() {
        let snapshot = ConversationSnapshot(
            key: ConversationKey(app: "slack", title: "team", threadID: "1792673677.999169"), kind: .channel,
            messages: [.init(id: "1", author: "Ana", text: "Por favor, revisa el despliegue antes de publicar este cambio para nuestros clientes.")],
            myName: nil, anchorFrame: nil)
        let (chat, _) = SuggestionEngine.prepare(snapshot, pseudonymize: true)
        let prompt = PromptBuilder.user(chat: chat, mode: "manual")
        #expect(prompt.contains("Output language: Spanish (es)"))
        #expect(prompt.contains("every thought, reply and gist"))
        #expect(prompt.contains("parent message and replies, not the surrounding channel"))
        #expect(prompt.contains("Keep JSON keys, strategy IDs and enum values unchanged"))
    }

    @Test func repairsWrongLanguageAndKeepsTheTargetInTheRepairTurn() async throws {
        let backend = LanguageBackend(responses: [ReplayBackend.canned, try russianOutput()])
        let result = try await SuggestionEngine(backend: backend, voices: VoiceRegistry.load()).run(russianRequest())
        #expect(result.repaired)
        #expect(result.verdict.read.gist.contains("Сначала"))
        let requests = await backend.requests
        #expect(requests.count == 2)
        #expect(requests[1].last?.content.contains("Russian (ru)") == true)
    }

    @Test func rejectsRepeatedWrongLanguageAfterOneRepair() async throws {
        let backend = LanguageBackend(responses: [ReplayBackend.canned, ReplayBackend.canned])
        do {
            _ = try await SuggestionEngine(backend: backend, voices: VoiceRegistry.load()).run(russianRequest())
            Issue.record("Wrong-language output must not become a validated result")
        } catch let error as LLMError {
            #expect(error.localizedDescription.contains("must use Russian"))
        }
        #expect(await backend.requests.count == 2)
    }

    @Test func shortOutputIsNotRejectedBasedOnAmbiguousLanguage() throws {
        let batch = VoiceBatch(read: .init(toMe: true, need: "no", tension: 0, register: "casual", clarity: 8, gist: "OK"),
            takes: [.init(voiceID: "logic", rel: 7, strategy: "facts_and_plan", thought: "[ETA]", reply: "👍", help: 7, risk: 0, fun: 0, issues: [])])
        try ConversationLanguage(code: "ru").validate(batch)
    }

    private func russianRequest() -> SuggestionRequest {
        SuggestionRequest(snapshot: ConversationSnapshot(key: .init(app: "slack", title: "Release"), kind: .channel,
            messages: [.init(id: "1", author: "Ana", text: "Пожалуйста, проверь развертывание перед выпуском этого изменения для наших клиентов.")],
            myName: nil, anchorFrame: nil), mode: "manual", pseudonymize: true)
    }

    private func russianOutput() throws -> String {
        var object = try #require(ResponseParser.extractJSONObject(ReplayBackend.canned))
        var read = try #require(object["read"] as? [String: Any])
        read["gist"] = "Сначала нужно проверить факты и согласовать дальнейшие действия с коллегами."
        object["read"] = read
        var voices = try #require(object["voices"] as? [String: [String: Any]])
        for id in voices.keys {
            voices[id]?["thought"] = "Тебе стоит сначала проверить факты и спокойно обсудить дальнейшие действия с коллегами."
            voices[id]?["reply"] = "Давайте сначала проверим состояние развертывания и согласуем дальнейшие действия для безопасного выпуска."
        }
        object["voices"] = voices
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}

private actor LanguageBackend: LLMBackend {
    nonisolated let origin = LLMOrigin.local
    private let responses: [String]
    private(set) var requests: [[ChatTurn]] = []

    init(responses: [String]) { self.responses = responses }

    func complete(system: String, turns: [ChatTurn], temperature: Double, maxTokens: Int, schema: Data?) async throws -> LLMResult {
        requests.append(turns)
        return LLMResult(text: responses[min(requests.count - 1, responses.count - 1)], latency: 0, model: "language-test")
    }
}
