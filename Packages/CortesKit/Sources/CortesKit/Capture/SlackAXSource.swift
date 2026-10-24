import Foundation
import os

/// Polls Slack's message list about once a second while Slack is frontmost. AX work stays on one serial queue.
public final class SlackAXSource: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.mrcat71.cortes.capture", qos: .userInitiated)
    private let reader = SlackAXReader()
    private let onEvent: @Sendable (CaptureEvent) -> Void
    private var timer: DispatchSourceTimer?
    private var myNameOverride: String?
    private var lastInactiveReason: String?
    private let log = Logger(subsystem: "io.github.mrcat71.cortes", category: "capture")

    public init(onEvent: @escaping @Sendable (CaptureEvent) -> Void) {
        self.onEvent = onEvent
    }

    public func setMyNameOverride(_ name: String?) {
        queue.async { self.myNameOverride = name }
    }

    public func start(interval: TimeInterval = 1.0) {
        queue.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.lastInactiveReason = nil
        }
    }

    /// Immediate read for the hotkey; it ignores the frontmost check.
    public func readNow(completion: @escaping @Sendable (CaptureEvent) -> Void) {
        queue.async {
            completion(self.read())
        }
    }

    private func poll() {
        guard SlackAXReader.isFrontmost else {
            let reason = SlackAXReader.isRunning ? "Slack is in the background" : "Slack isn't running"
            if reason != lastInactiveReason {
                lastInactiveReason = reason
                onEvent(.inactive(reason))
            }
            return
        }
        lastInactiveReason = nil
        onEvent(read())
    }

    private func read() -> CaptureEvent {
        do {
            return .snapshot(try reader.read(myNameOverride: myNameOverride))
        } catch SlackAXReader.ReadError.notTrusted {
            return .notTrusted
        } catch {
            log.debug("Slack read failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }
}
