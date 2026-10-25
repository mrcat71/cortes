import AVFoundation
import Foundation
import Speech
import Synchronization

/// A single audio track. SpeechAnalyzer and both transcriber modules run on-device.
@available(macOS 26, *)
@MainActor public final class OnDeviceSpeech {
    private let analyzer: SpeechAnalyzer
    public let input: SpeechAudioInput
    private var resultsTask: Task<Void, Never>?

    private init(analyzer: SpeechAnalyzer, input: SpeechAudioInput) {
        self.analyzer = analyzer
        self.input = input
    }

    public static func start(
        locale: Locale, onText: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (String) -> Void,
        onStatus: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> OnDeviceSpeech {
        let module: any SpeechModule
        let readResults: @Sendable () async throws -> Void
        onStatus("Checking on-device speech language support…")
        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = SpeechTranscriber(
                locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
            module = transcriber
            readResults = {
                for try await result in transcriber.results where result.isFinal {
                    onText(String(result.text.characters))
                }
            }
        } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = DictationTranscriber(locale: supported, preset: .longDictation)
            module = transcriber
            readResults = {
                for try await result in transcriber.results where result.isFinal {
                    onText(String(result.text.characters))
                }
            }
        } else {
            throw LLMError.unavailable(
                "On-device speech recognition doesn't support \(locale.identifier) on this Mac. Choose another language."
            )
        }
        onStatus("Preparing speech language assets…")
        if let download = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            onStatus("Downloading on-device speech language assets…")
            let progress = Task {
                var previous = -1
                while !Task.isCancelled {
                    let percent = Int(download.progress.fractionCompleted * 100)
                    if percent != previous {
                        onStatus("Downloading speech language assets: \(percent)%")
                        previous = percent
                    }
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                }
            }
            defer { progress.cancel() }
            try await download.downloadAndInstall()
        }
        try Task.checkCancellation()
        onStatus("Selecting speech audio format…")
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw LLMError.unavailable("No compatible on-device speech audio format.")
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let input = SpeechAudioInput(format: format, continuation: continuation, onError: onError)
        let analyzer = SpeechAnalyzer(modules: [module])
        let speech = OnDeviceSpeech(analyzer: analyzer, input: input)
        speech.resultsTask = Task {
            do { try await readResults() } catch { if !Task.isCancelled { onError(error.localizedDescription) } }
        }
        do {
            onStatus("Starting on-device speech analyzer…")
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: stream)
            onStatus("Speech analyzer ready")
            return speech
        } catch {
            speech.stop()
            throw error
        }
    }

    public func stop() {
        input.finish()
        resultsTask?.cancel()
        resultsTask = nil
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }

    /// Finishes a finite synthetic/file input and waits for its final transcription results.
    public func finishAndDrain() async throws {
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        resultsTask = nil
    }
}

/// Owns conversion on one serial queue. Audio buffers must be owned copies before being submitted.
@available(macOS 26, *)
public final class SpeechAudioInput: @unchecked Sendable {
    private struct OwnedBuffer: @unchecked Sendable {
        // Submitted buffers are owned copies and are never mutated after this handoff.
        let buffer: AVAudioPCMBuffer
    }
    private let queue = DispatchQueue(label: "io.github.mrcat71.cortes.speech-input")
    private let pending = DispatchSemaphore(value: 32)
    private let failed = Mutex(false)
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let onError: @Sendable (String) -> Void
    private var converter: AVAudioConverter?
    private var finished = false

    init(
        format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
        onError: @escaping @Sendable (String) -> Void
    ) {
        self.format = format
        self.continuation = continuation
        self.onError = onError
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        guard !failed.withLock({ $0 }) else { return }
        guard pending.wait(timeout: .now()) == .success else {
            reportFailure("Speech audio processing cannot keep up. Listening stopped.")
            return
        }
        // AnalyzerInput only accepts compatible PCM layouts. Convert before constructing it.
        let input = OwnedBuffer(buffer: buffer)
        queue.async { [self] in
            defer { pending.signal() }
            guard !finished, !failed.withLock({ $0 }) else { return }
            do {
                let buffer = input.buffer
                let output: AVAudioPCMBuffer
                if buffer.format == format {
                    output = buffer
                } else {
                    if converter?.inputFormat != buffer.format {
                        converter = AVAudioConverter(from: buffer.format, to: format)
                        converter?.primeMethod = .none
                    }
                    guard let converter,
                        let converted = AVAudioPCMBuffer(
                            pcmFormat: format,
                            frameCapacity:
                                AVAudioFrameCount(
                                    ceil(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate))
                                + 32)
                    else { throw LLMError.unavailable("Cannot convert captured audio for speech recognition.") }
                    var consumed = false
                    var error: NSError?
                    let status = converter.convert(to: converted, error: &error) { _, state in
                        if consumed {
                            state.pointee = .noDataNow
                            return nil
                        }
                        consumed = true
                        state.pointee = .haveData
                        return buffer
                    }
                    if let error { throw error }
                    guard status != .error else { throw LLMError.unavailable("Speech audio conversion failed.") }
                    output = converted
                }
                guard output.frameLength > 0 else { return }
                if case .dropped = continuation.yield(AnalyzerInput(buffer: output)) {
                    throw LLMError.unavailable(
                        "Speech recognition cannot keep up with captured audio. Listening stopped.")
                }
            } catch {
                finished = true
                reportFailure(error.localizedDescription)
            }
        }
    }

    private func reportFailure(_ message: String) {
        let first = failed.withLock { failed in
            if failed { return false }
            failed = true
            return true
        }
        guard first else { return }
        onError(message)
        continuation.finish()
    }

    public func finish() {
        queue.async {
            self.finished = true
            self.converter = nil
            self.continuation.finish()
        }
    }

    public static func copy(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else {
            return nil
        }
        output.frameLength = input.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        guard source.count == target.count else { return nil }
        for index in source.indices {
            guard let from = source[index].mData, let to = target[index].mData,
                target[index].mDataByteSize >= source[index].mDataByteSize
            else { return nil }
            memcpy(to, from, Int(source[index].mDataByteSize))
        }
        return output
    }
}
