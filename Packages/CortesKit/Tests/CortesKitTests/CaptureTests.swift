import AVFoundation
import Foundation
import Speech
import Synchronization
import Testing

@testable import CortesKit

@Suite struct CaptureTests {
    @Test func rejectsQueuedContextAfterPermissionOrScopeChanges() throws {
        let selected = try #require(
            AppTextContext.snapshot(appID: "com.example.App", title: "Test", text: "Selected text"))
        let visible = try #require(
            AppTextContext.snapshot(appID: "com.example.App", title: "Test", text: "Window text", scope: .visibleWindow)
        )
        #expect(CapturePrivacy.allowsTextContext(selected, apps: ["com.example.App"], scope: .selection))
        #expect(!CapturePrivacy.allowsTextContext(selected, apps: [], scope: .selection))
        #expect(!CapturePrivacy.allowsTextContext(visible, apps: ["com.example.App"], scope: .selection))
        #expect(!CapturePrivacy.allowsTextContext(selected, apps: ["com.example.Other"], scope: .selection))
        #expect(CapturePrivacy.allowsTextContext(visible, apps: ["com.example.App"], scope: .visibleWindow))
    }

    @Test func audioOverloadStopsExplicitlyInsteadOfSilentlyDroppingSpeech() async throws {
        guard #available(macOS 26, *) else { return }
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        buffer.int16ChannelData?.pointee.initialize(repeating: 0, count: 160)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let errors = Mutex<[String]>([])
        let input = SpeechAudioInput(format: format, continuation: continuation) { error in
            errors.withLock { $0.append(error) }
        }
        for _ in 0..<50 { input.append(buffer) }
        input.finish()
        for await _ in stream {}
        #expect(errors.withLock { $0.count } == 1)
    }

    @Test func localCallBackendRejectsRemoteEndpointsAndRedirects() async throws {
        #expect(throws: LLMError.self) {
            try OllamaBackend.localOnly(config: OllamaConfig(baseURL: "https://example.invalid"))
        }
        _ = try OllamaBackend.localOnly(config: OllamaConfig())
        let target = try #require(URL(string: "https://example.invalid"))
        let source = try #require(URL(string: "http://127.0.0.1:11434/api/chat"))
        let response = try #require(
            HTTPURLResponse(
                url: source, statusCode: 307, httpVersion: nil, headerFields: ["Location": target.absoluteString]))
        let task = URLSession.shared.dataTask(with: source)
        let rejected = await withCheckedContinuation { continuation in
            NoRedirects().urlSession(
                URLSession.shared, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: target)
            ) {
                continuation.resume(returning: $0 == nil)
            }
        }
        #expect(rejected)
    }

    @Test(arguments: [
        ("http://127.0.0.1:11434", true), ("http://localhost:11434/", true),
        ("http://[::1]:11434", true), ("https://localhost:11434", true),
        ("http://localhost.attacker.example", false), ("http://localhost@attacker.example", false),
        ("http://192.168.1.10:11434", false), ("file:///tmp/model", false), ("invalid", false),
    ])
    func callInferenceMustStayOnLoopback(url: String, allowed: Bool) {
        #expect(CapturePrivacy.isLoopback(url) == allowed)
    }

    @Test(arguments: [
        ("com.example.Call", "com.example.Call", true),
        ("com.example.Call.helper", "com.example.Call", true),
        ("com.example.Callback", "com.example.Call", false),
        ("com.other.Call", "com.example.Call", false), ("com.any.App", "", false),
    ])
    func audioIsScopedToSelectedAppAndItsHelpers(process: String, selected: String, matches: Bool) {
        #expect(CapturePrivacy.matchesAudioApp(processBundleID: process, selectedBundleID: selected) == matches)
    }

    @Test func genericContextIsSanitizedBoundedAndUnattributed() throws {
        let context = try #require(
            AppTextContext.snapshot(
                appID: "com.example.Chat", title: "Window", text: "Hello\u{200B}" + String(repeating: "x", count: 8000))
        )
        #expect(context.kind == .context)
        #expect(context.messages[0].text.count == 6000)
        #expect(!context.messages[0].text.contains("\u{200B}"))
        #expect(context.myName == nil && !context.messages[0].isMe)
        #expect(AppTextContext.snapshot(appID: "app", title: "empty", text: " \n") == nil)
        let changed = try #require(
            AppTextContext.snapshot(appID: "com.example.Chat", title: "Window", text: "New text"))
        #expect(context.key == changed.key && context.revision != changed.revision)
        let (prepared, _) = SuggestionEngine.prepare(context, pseudonymize: true)
        #expect(PromptBuilder.situation(chat: prepared, mode: "manual").contains("authorship are unknown"))
    }

    @Test func callTranscriptKeepsTracksSeparateAndUsesSessionScopedConsent() {
        var transcript = CallTranscript(appName: "Example Call")
        #expect(transcript.snapshot.messages.isEmpty)
        transcript.append("What can we do?", isMe: false)
        transcript.append("Let me check.", isMe: true)
        #expect(transcript.messages.map(\.isMe) == [false, true])
        #expect(transcript.messages.map(\.author) == ["Call participants", "ME"])
        let (prepared, _) = SuggestionEngine.prepare(transcript.snapshot, pseudonymize: true)
        let prompt = PromptBuilder.situation(chat: prepared, mode: "auto")
        #expect(prompt.contains("SAY next"))
        #expect(prompt.contains("Focus: message 1"))
        #expect(prompt.contains("ME already wrote after it"))
        #expect(CallTranscript(appName: "Example Call").key != transcript.key)
    }

    @Test func callTranscriptBoundsMemoryWithoutDeduplicatingRealRepeatedSpeech() {
        var transcript = CallTranscript(appName: "Call")
        transcript.append(" \n", isMe: false)
        #expect(transcript.messages.isEmpty)
        for _ in 0..<50 { transcript.append("Again " + String(repeating: "x", count: 1800), isMe: false) }
        #expect(transcript.messages.count == 40)
        #expect(Set(transcript.messages.map(\.id)).count == 40)
        #expect(transcript.messages.allSatisfy { $0.text.count == 1200 })
        #expect(transcript.messages.first?.id == "11")
    }

    @Test func ownedAudioCopyAndRateConversion() async throws {
        guard #available(macOS 26, *) else { return }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        for channel in 0..<2 {
            let samples = try #require(buffer.floatChannelData?[channel])
            for index in 0..<4800 { samples[index] = 0.1 }
        }
        let copy = try #require(SpeechAudioInput.copy(buffer))
        buffer.floatChannelData?[0][0] = 0.9
        #expect(copy.floatChannelData?[0][0] == 0.1)
        #expect(copy.frameLength == 4800 && copy.format == format)
        let target = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true))
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let feeder = SpeechAudioInput(format: target, continuation: continuation) {
            Issue.record(Comment(rawValue: $0))
        }
        for _ in 0..<10 { feeder.append(copy) }
        feeder.finish()
        var frames = 0
        for await input in stream {
            #expect(input.buffer.format == target)
            frames += Int(input.buffer.frameLength)
        }
        // A streaming resampler may retain its short filter tail, but must not drop a tail per chunk.
        #expect(frames > 15600)
        #expect(frames <= 16000)
    }

}
