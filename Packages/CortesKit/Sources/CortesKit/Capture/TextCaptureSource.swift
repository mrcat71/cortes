import AppKit
import Foundation
import os

/// Polls the frontmost app. Generic app content is read only after explicit per-app opt-in.
public final class TextCaptureSource: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.mrcat71.cortes.capture", qos: .userInitiated)
    private let reader = SlackAXReader()
    private let appReader = AppAXReader()
    private var allowedApps: Set<String> = []
    private var scope = AppTextScope.selection
    private let onEvent: @Sendable (CaptureEvent) -> Void
    private var timer: DispatchSourceTimer?
    private var myNameOverride: String?
    private var myNameFallback: String?
    private var lastInactiveReason: String?
    private let log = Logger(subsystem: "io.github.mrcat71.cortes", category: "capture")

    public init(onEvent: @escaping @Sendable (CaptureEvent) -> Void) {
        self.onEvent = onEvent
    }

    public func setMyNameOverride(_ name: String?) {
        queue.async { self.myNameOverride = name }
    }

    public func configure(apps: [String], scope: AppTextScope) {
        queue.async {
            self.allowedApps = Set(apps)
            self.scope = scope
        }
    }

    /// The name detected in an earlier run, used when Slack's sidebar "you" row isn't rendered.
    public func setMyNameFallback(_ name: String?) {
        queue.async { self.myNameFallback = name }
    }

    public func start(interval: TimeInterval = 1.0) {
        queue.async { [self] in
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

    /// Immediate read of the frontmost app for the hotkey, subject to the same per-app opt-in.
    public func readNow(completion: @escaping @Sendable (CaptureEvent) -> Void) {
        queue.async {
            completion(self.read())
        }
    }

    private func poll() {
        let event = read()
        if case .inactive(let reason) = event {
            guard reason != lastInactiveReason else { return }
            lastInactiveReason = reason
        } else {
            lastInactiveReason = nil
        }
        onEvent(event)
    }

    private func read() -> CaptureEvent {
        do {
            guard let app = NSWorkspace.shared.frontmostApplication else { return .inactive("No focused application") }
            if app.bundleIdentifier == SlackAXReader.bundleID {
                return .snapshot(try reader.read(myNameOverride: myNameOverride, myNameFallback: myNameFallback))
            }
            guard let id = app.bundleIdentifier, allowedApps.contains(id) else {
                return .inactive("Text capture is not enabled for this app")
            }
            return .snapshot(try appReader.read(application: app, scope: scope))
        } catch SlackAXReader.ReadError.notTrusted {
            return .notTrusted
        } catch {
            log.debug("Application text read failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }
}
