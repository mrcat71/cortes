import AVFoundation
import CoreAudio
import Foundation
import os

@MainActor public protocol VoiceCaptureSession: AnyObject {
    func stop()
}

/// Pure audio capture. No ScreenCaptureKit, camera, screen frames, recording files or cloud recognizer.
@available(macOS 26, *)
@MainActor public final class VoiceCallCapture: VoiceCaptureSession {
    private var tap: ProcessAudioTap?
    private var remote: OnDeviceSpeech?
    private var microphone: OnDeviceSpeech?
    private var engine: AVAudioEngine?

    public init() {}

    public func start(
        bundleID: String, locale: Locale, includeMicrophone: Bool,
        onText: @escaping @Sendable (String, Bool) -> Void, onError: @escaping @Sendable (String) -> Void,
        onStatus: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        guard !bundleID.isEmpty else { throw LLMError.unavailable("Select a call application before listening.") }
        do {
            remote = try await OnDeviceSpeech.start(
                locale: locale, onText: { onText($0, false) }, onError: onError, onStatus: onStatus)
            try Task.checkCancellation()
            if includeMicrophone {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw LLMError.unavailable(
                        "Microphone permission was denied. Enable it in System Settings or turn off microphone capture."
                    )
                }
                microphone = try await OnDeviceSpeech.start(
                    locale: locale, onText: { onText($0, true) }, onError: onError, onStatus: onStatus)
            }
            try Task.checkCancellation()
            guard let input = remote?.input else { throw CancellationError() }
            let tap = ProcessAudioTap()
            self.tap = tap
            try tap.start(bundleID: bundleID, input: input, onError: onError)
            if let microphone {
                let input = microphone.input
                let engine = AVAudioEngine()
                let node = engine.inputNode
                let format = node.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else {
                    throw LLMError.unavailable("No usable microphone input device.")
                }
                node.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
                    guard let copy = SpeechAudioInput.copy(buffer) else {
                        onError("Cannot copy microphone audio. Listening stopped.")
                        return
                    }
                    input.append(copy)
                }
                self.engine = engine
                engine.prepare()
                try engine.start()
            }
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        tap?.stop()
        tap = nil
        remote?.stop()
        microphone?.stop()
        remote = nil
        microphone = nil
    }
}

@available(macOS 26, *)
@MainActor private final class ProcessAudioTap {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "io.github.mrcat71.cortes.call-audio", qos: .userInitiated)
    private static let log = Logger(subsystem: "io.github.mrcat71.cortes", category: "call-audio")

    func start(bundleID: String, input: SpeechAudioInput, onError: @escaping @Sendable (String) -> Void) throws {
        var address = property(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size))
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try processes.withUnsafeMutableBytes { bytes in
            try check(
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, bytes.baseAddress!))
        }
        var selected: [AudioObjectID] = []
        var bundleIDs = Set([bundleID])
        for process in processes {
            var address = property(kAudioProcessPropertyBundleID)
            guard AudioObjectHasProperty(process, &address) else { continue }
            var value: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &value) {
                AudioObjectGetPropertyData(process, &address, 0, nil, &size, $0)
            }
            // Processes can disappear while the list is being enumerated. No broad capture fallback.
            if status == kAudioHardwareBadObjectError { continue }
            try check(status)
            guard let value else { continue }
            let id = value.takeRetainedValue() as String
            if CapturePrivacy.matchesAudioApp(processBundleID: id, selectedBundleID: bundleID) {
                selected.append(process)
                bundleIDs.insert(id)
            }
        }
        let description = CATapDescription(monoMixdownOfProcesses: selected)
        description.name = "Cortes call audio"
        description.isPrivate = true
        description.isExclusive = false
        description.muteBehavior = .unmuted
        description.bundleIDs = Array(bundleIDs)
        description.isProcessRestoreEnabled = true
        try check(AudioHardwareCreateProcessTap(description, &tap))

        var tapFormat = AudioStreamBasicDescription()
        address = property(kAudioTapPropertyFormat)
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &tapFormat))
        guard let format = AVAudioFormat(streamDescription: &tapFormat) else {
            throw LLMError.unavailable(
                "The selected app has no usable audio output. Join the call first, then try again.")
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Cortes private call input",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device))
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, queue) { _, list, _, _, _ in
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
                guard let first = buffers.first, first.mDataByteSize > 0 else { return }
                guard let borrowed = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil),
                    let copy = SpeechAudioInput.copy(borrowed)
                else {
                    onError("Cannot read captured app audio. Listening stopped.")
                    return
                }
                input.append(copy)
            })
        try check(AudioDeviceStart(device, ioProc))
    }

    func stop() {
        if let ioProc {
            report(AudioDeviceStop(device, ioProc))
            report(AudioDeviceDestroyIOProcID(device, ioProc))
        }
        ioProc = nil
        if device != kAudioObjectUnknown { report(AudioHardwareDestroyAggregateDevice(device)) }
        device = AudioObjectID(kAudioObjectUnknown)
        if tap != kAudioObjectUnknown { report(AudioHardwareDestroyProcessTap(tap)) }
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    private func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw LLMError.unavailable(
                "Call audio capture failed (Core Audio \(status)). Check System Settings → Privacy & Security → Screen & System Audio Recording, then retry."
            )
        }
    }

    private func report(_ status: OSStatus) {
        if status != noErr { Self.log.error("Audio capture cleanup failed: \(status)") }
    }
}
