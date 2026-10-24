import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CortesKit
import Observation
import os

enum Mode: String, CaseIterable, Identifiable {
    case manual
    case auto
    case paused

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "Manual (hotkey only)"
        case .auto: "Auto"
        case .paused: "Paused"
        }
    }
}

enum EndpointPreset: String, CaseIterable, Identifiable {
    case general
    case codingPlan
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "z.ai API (pay-as-you-go)"
        case .codingPlan: "z.ai Coding Plan"
        case .custom: "Custom"
        }
    }

    var url: String? {
        switch self {
        case .general: ZAIEndpoint.general
        case .codingPlan: ZAIEndpoint.codingPlan
        case .custom: nil
        }
    }
}

enum Engine: String, CaseIterable, Identifiable {
    case local
    case cloud
    case replay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: "Local (Ollama)"
        case .cloud: "z.ai cloud"
        case .replay: "Replay (offline)"
        }
    }
}

enum OverlayPhase {
    case hidden
    case thinking(ConversationKey)
    case consent(ConversationSnapshot)
    case result(SuggestionResult)
    case failure(String)

    var isVisible: Bool {
        if case .hidden = self { return false }
        return true
    }
}

@Observable
final class AppModel {
    static let bundleID = "io.github.mrcat71.cortes"
    static let keychainAccount = "zai-api-key"
    static let demoWindowTitle = "Demo Chat"
    static let demoWindowID = "demo-chat"
    static let modelSuggestions = ["glm-5.2", "glm-5-turbo", "glm-4.7", "glm-4.5-air", "glm-5.3"]
    static let ollamaModelSuggestions = ["gemma4:12b", "gemma4:26b", "gemma4:e4b", "gemma4:12b-mlx"]

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let log = Logger(subsystem: AppModel.bundleID, category: "app")

    // MARK: Settings (UserDefaults; the API key lives in Keychain)

    var mode: Mode { didSet { defaults.set(mode.rawValue, forKey: "mode"); applyMode() } }
    var sensitivity: Sensitivity { didSet { defaults.set(sensitivity.rawValue, forKey: "sensitivity") } }
    var baseURL: String { didSet { defaults.set(baseURL, forKey: "baseURL") } }
    var modelName: String { didSet { defaults.set(modelName, forKey: "model") } }
    var disableThinking: Bool { didSet { defaults.set(disableThinking, forKey: "disableThinking") } }
    var pseudonymize: Bool { didSet { defaults.set(pseudonymize, forKey: "pseudonymize") } }
    var engine: Engine { didSet { defaults.set(engine.rawValue, forKey: "engine") } }
    var ollamaURL: String { didSet { defaults.set(ollamaURL, forKey: "ollamaURL") } }
    var ollamaModel: String { didSet { defaults.set(ollamaModel, forKey: "ollamaModel") } }
    var myNameOverride: String {
        didSet {
            defaults.set(myNameOverride, forKey: "myName")
            capture?.setMyNameOverride(myNameOverride.isEmpty ? nil : myNameOverride)
        }
    }
    var allowlist: [String] { didSet { defaults.set(allowlist, forKey: "allowlist") } }
    private(set) var hasAPIKey = false

    // MARK: Runtime state

    private(set) var axTrusted = AXIsProcessTrusted()
    private(set) var captureStatus = "Starting…"
    private(set) var current: ConversationSnapshot?
    private(set) var phase: OverlayPhase = .hidden
    private(set) var stale = false
    private(set) var connectionTestResult: String?
    var copiedVoiceID: String?
    var overlayHovered = false
    var demoScenarioID: String { didSet { demoReset() } }
    private(set) var demoVisible = 0

    let voices: [VoiceDefinition]
    let scenarios: [Scenario]

    @ObservationIgnored private var overlay: OverlayController?
    @ObservationIgnored private var capture: SlackAXSource?
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var inflight: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var trustPoll: Timer?
    @ObservationIgnored private var cachedAPIKey: String?
    @ObservationIgnored private var lastFire: [String: Date] = [:]
    @ObservationIgnored private var lastGlobalFire = Date.distantPast
    @ObservationIgnored private var firedRevisions: Set<String> = []
    @ObservationIgnored private var recentTop: [String] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false

    init() {
        let defaults = UserDefaults.standard
        mode = Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .manual
        sensitivity = Sensitivity(rawValue: defaults.string(forKey: "sensitivity") ?? "") ?? .medium
        baseURL = defaults.string(forKey: "baseURL") ?? ZAIEndpoint.general
        modelName = defaults.string(forKey: "model") ?? "glm-5.2"
        disableThinking = defaults.object(forKey: "disableThinking") as? Bool ?? true
        pseudonymize = defaults.object(forKey: "pseudonymize") as? Bool ?? true
        // First migration step from the old replay toggle; afterwards the engine key wins.
        engine = Engine(rawValue: defaults.string(forKey: "engine") ?? "")
            ?? (defaults.bool(forKey: "useReplay") ? .replay : .local)
        ollamaURL = defaults.string(forKey: "ollamaURL") ?? OllamaConfig.defaultURL
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? OllamaConfig.defaultModel
        myNameOverride = defaults.string(forKey: "myName") ?? ""
        allowlist = defaults.stringArray(forKey: "allowlist") ?? []
        voices = VoiceRegistry.load()
        scenarios = Scenario.loadBundled()
        demoScenarioID = scenarios.first?.id ?? ""
        hasAPIKey = KeychainStore.read(service: Self.bundleID, account: Self.keychainAccount) != nil
    }

    func start() {
        guard !started else { return }
        started = true
        overlay = OverlayController(model: self)
        hotKey = GlobalHotKey(keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey) { [weak self] in
            self?.hotKeyPressed()
        }
        if hotKey == nil { log.error("Couldn't register the ⌃⌥V hotkey") }
        let source = SlackAXSource { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        source.setMyNameOverride(myNameOverride.isEmpty ? nil : myNameOverride)
        source.setMyNameFallback(defaults.string(forKey: "detectedSlackName"))
        capture = source
        observeSystem()
        if !axTrusted { pollTrust() }
        demoReset()
        applyMode()
        if engine == .local { warmUpLocalModel() }
    }

    /// Loads the model and caches the system prompt's prefix right after launch, so the first real
    /// request only pays generation time. Ollama keeps it resident for the configured keep-alive.
    private func warmUpLocalModel() {
        let backend = OllamaBackend(config: OllamaConfig(baseURL: ollamaURL, model: ollamaModel))
        let system = PromptBuilder.system(voices: voices.filter(\.enabled))
        let log = self.log
        Task(priority: .utility) {
            do {
                try await backend.warmUp(system: system)
                log.notice("Ollama model warmed up")
            } catch {
                log.notice("Ollama warm-up skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Derived

    var menuBarSymbol: String {
        if mode == .paused { return "moon.zzz" }
        if !axTrusted { return "exclamationmark.triangle" }
        if case .thinking = phase { return "ellipsis.bubble" }
        return mode == .auto ? "brain" : "brain.head.profile"
    }

    var endpointPreset: EndpointPreset {
        get { EndpointPreset.allCases.first { $0.url == baseURL } ?? .custom }
        set { if let url = newValue.url { baseURL = url } }
    }

    func isAllowed(_ key: ConversationKey) -> Bool {
        key.app == "demo" || allowlist.contains(key.id)
    }

    func setAllowed(_ key: ConversationKey, _ allowed: Bool) {
        if allowed {
            if !allowlist.contains(key.id) { allowlist.append(key.id) }
        } else {
            allowlist.removeAll { $0 == key.id }
        }
    }

    func voice(_ id: String) -> VoiceDefinition? {
        voices.first { $0.id == id }
    }

    // MARK: Capture

    private func applyMode() {
        guard started else { return }
        if mode == .paused {
            capture?.stop()
            wipe()
            captureStatus = "Paused"
        } else {
            capture?.start()
        }
    }

    private func handle(_ event: CaptureEvent) {
        guard mode != .paused else { return }
        switch event {
        case .notTrusted:
            if axTrusted { log.notice("Accessibility trust lost") }
            axTrusted = false
            captureStatus = "Accessibility permission needed"
        case .inactive(let reason):
            captureStatus = reason
            if current?.key.app == "slack" { leaveConversation() }
        case .failed(let message):
            captureStatus = message
            if current?.key.app == "slack" { leaveConversation() }
        case .snapshot(let snapshot):
            if !axTrusted { log.notice("Accessibility trusted; reading Slack") }
            axTrusted = true
            if myNameOverride.isEmpty, let name = snapshot.myName, name != defaults.string(forKey: "detectedSlackName") {
                defaults.set(name, forKey: "detectedSlackName")
                capture?.setMyNameFallback(name)
            }
            captureStatus = "Reading “\(snapshot.key.title)”"
            ingest(snapshot)
        }
    }

    private func ingest(_ snapshot: ConversationSnapshot) {
        let previous = current
        current = snapshot
        if let previous, previous.key != snapshot.key {
            cancelWork()
            hideOverlay()
            return // a conversation switch never triggers auto mode
        }
        guard let previous, previous.revision != snapshot.revision else {
            if phase.isVisible { overlay?.update(anchor: snapshot.anchorFrame) }
            return
        }
        if case .result(let result) = phase, result.key == snapshot.key {
            stale = result.revision != snapshot.revision
        }
        if phase.isVisible { overlay?.update(anchor: snapshot.anchorFrame) }
        if mode == .auto { scheduleAuto() }
    }

    private func leaveConversation() {
        current = nil
        cancelWork()
        hideOverlay()
    }

    private func wipe() {
        current = nil
        firedRevisions.removeAll()
        lastFire.removeAll()
        recentTop.removeAll()
        cancelWork()
        hideOverlay()
    }

    // MARK: Triggers

    private func scheduleAuto() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.autoFire()
        }
    }

    private func autoFire() {
        guard mode == .auto, let snapshot = current, isAllowed(snapshot.key), !overlayHovered else { return }
        guard let last = snapshot.messages.last, !last.isMe else { return }
        guard !firedRevisions.contains(snapshot.key.id + "#" + snapshot.revision) else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFire[snapshot.key.id] ?? .distantPast) > sensitivity.conversationCooldown,
              now.timeIntervalSince(lastGlobalFire) > sensitivity.globalCooldown
        else { return }
        guard TriggerPolicy.attentionScore(snapshot) >= sensitivity.threshold else { return }
        run(snapshot, manual: false)
    }

    func hotKeyPressed() {
        guard mode != .paused else {
            captureStatus = "Paused"
            return
        }
        if NSApp.isActive, NSApp.keyWindow?.title == Self.demoWindowTitle {
            demoAsk()
            return
        }
        if case .result(let result) = phase, !stale, result.key == current?.key {
            hideOverlay() // a second press dismisses fresh suggestions
            return
        }
        capture?.readNow { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                self.handle(event)
                switch event {
                case .snapshot(let snapshot): self.run(snapshot, manual: true)
                case .notTrusted: self.showFailure("Cortes needs Accessibility permission to read Slack.")
                case .failed(let message), .inactive(let message): self.showFailure(message)
                }
            }
        }
    }

    // MARK: Generation

    func run(_ snapshot: ConversationSnapshot, manual: Bool) {
        cancelWork()
        guard isAllowed(snapshot.key) else {
            if manual {
                phase = .consent(snapshot)
                showOverlay(anchor: snapshot.anchorFrame)
            }
            return
        }
        let backend: any LLMBackend
        switch engine {
        case .replay:
            backend = ReplayBackend()
        case .local:
            backend = OllamaBackend(config: OllamaConfig(baseURL: ollamaURL, model: ollamaModel))
        case .cloud:
            guard let key = apiKey() else {
                showFailure(LLMError.missingKey.localizedDescription, anchor: snapshot.anchorFrame)
                return
            }
            backend = ZAIBackend(config: ZAIConfig(
                baseURL: baseURL, model: modelName, apiKey: key, disableThinking: disableThinking))
        }
        firedRevisions.insert(snapshot.key.id + "#" + snapshot.revision)
        lastFire[snapshot.key.id] = Date()
        lastGlobalFire = Date()
        stale = false
        phase = .thinking(snapshot.key)
        showOverlay(anchor: snapshot.anchorFrame)

        let engine = SuggestionEngine(backend: backend, voices: voices.filter(\.enabled), recentTop: recentTop)
        let request = SuggestionRequest(snapshot: snapshot, mode: manual ? "manual" : "auto", pseudonymize: pseudonymize)
        inflight = Task { [weak self] in
            do {
                let result = try await engine.run(request)
                guard !Task.isCancelled, let self else { return }
                self.finish(result, auto: !manual)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.log.error("Generation failed: \(error.localizedDescription, privacy: .public)")
                self.phase = .failure(error.localizedDescription)
            }
        }
    }

    private func finish(_ result: SuggestionResult, auto: Bool) {
        if let current, current.key != result.key { return } // the user moved on: drop it
        stale = current.map { $0.revision != result.revision } ?? false
        phase = .result(result)
        if let top = result.verdict.recommended { recentTop = Array((recentTop + [top]).suffix(2)) }
        if auto { scheduleAutoDismiss() }
    }

    func retry() {
        if let current { run(current, manual: true) }
    }

    func allowAndAsk(_ snapshot: ConversationSnapshot) {
        setAllowed(snapshot.key, true)
        run(snapshot, manual: true)
    }

    func copy(_ ranked: RankedTake) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ranked.take.reply, forType: .string)
        // Ask clipboard managers not to keep it (nspasteboard.org convention).
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        copiedVoiceID = ranked.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if self?.copiedVoiceID == ranked.id { self?.copiedVoiceID = nil }
        }
    }

    // MARK: Overlay

    private func showOverlay(anchor: CGRect?) {
        dismissTask?.cancel()
        overlay?.show(anchor: anchor)
    }

    private func showFailure(_ message: String, anchor: CGRect? = nil) {
        phase = .failure(message)
        showOverlay(anchor: anchor)
    }

    func dismissOverlay() {
        cancelWork()
        hideOverlay()
    }

    private func hideOverlay() {
        dismissTask?.cancel()
        phase = .hidden
        stale = false
        overlay?.hide()
    }

    private func scheduleAutoDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled, let self else { return }
                if !self.overlayHovered { break }
            }
            self?.hideOverlay()
        }
    }

    private func cancelWork() {
        inflight?.cancel()
        inflight = nil
        debounce?.cancel()
        debounce = nil
    }

    // MARK: API key

    func apiKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["ZAI_API_KEY"], !env.isEmpty { return env }
        if let cachedAPIKey { return cachedAPIKey }
        cachedAPIKey = KeychainStore.read(service: Self.bundleID, account: Self.keychainAccount)
        return cachedAPIKey
    }

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try KeychainStore.write(trimmed, service: Self.bundleID, account: Self.keychainAccount)
        cachedAPIKey = trimmed
        hasAPIKey = true
    }

    func removeAPIKey() throws {
        try KeychainStore.delete(service: Self.bundleID, account: Self.keychainAccount)
        cachedAPIKey = nil
        hasAPIKey = false
    }

    func testConnection() async {
        switch engine {
        case .replay:
            connectionTestResult = "Replay answers from a canned response; no connection needed."
        case .local:
            connectionTestResult = "Checking…"
            connectionTestResult = await OllamaBackend(
                config: OllamaConfig(baseURL: ollamaURL, model: ollamaModel)).status()
        case .cloud:
            guard let key = apiKey() else {
                connectionTestResult = LLMError.missingKey.localizedDescription
                return
            }
            connectionTestResult = "Testing…"
            let backend = ZAIBackend(config: ZAIConfig(
                baseURL: baseURL, model: modelName, apiKey: key, disableThinking: disableThinking, timeout: 30))
            do {
                let result = try await backend.complete(
                    system: "Answer with a JSON object only.",
                    turns: [ChatTurn(role: "user", content: "Return {\"ok\":true}")],
                    temperature: 0, maxTokens: 20)
                connectionTestResult = "OK: \(result.model) answered in \(String(format: "%.1f", result.latency)) s"
            } catch {
                connectionTestResult = error.localizedDescription
            }
        }
    }

    // MARK: Permissions and system events

    func requestAccessibility() {
        // The literal value of kAXTrustedCheckOptionPrompt, which Swift 6 flags as shared mutable state.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        axTrusted = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        pollTrust()
    }

    private func pollTrust() {
        trustPoll?.invalidate()
        trustPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.axTrusted = true
                self.trustPoll?.invalidate()
                self.trustPoll = nil
            }
        }
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wipe() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.wipe() }
        })
        // Demo suggestions belong to the Demo Chat window; don't leave them floating over other apps.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.current?.key.app == "demo" else { return }
                self.cancelWork()
                self.hideOverlay()
            }
        })
    }

    // MARK: Demo chat

    var demoScenario: Scenario? {
        scenarios.first { $0.id == demoScenarioID } ?? scenarios.first
    }

    var demoMessages: [ChatMessage] {
        demoScenario?.snapshot(visibleCount: demoVisible).messages ?? []
    }

    var demoHasNext: Bool {
        demoVisible < (demoScenario?.lines.count ?? 0)
    }

    func demoReset() {
        demoVisible = demoScenario?.preloaded ?? 0
        if current?.key.app == "demo" || current == nil {
            cancelWork()
            hideOverlay()
            current = demoSnapshot()
        }
    }

    func demoAppeared() {
        current = demoSnapshot()
    }

    func demoNext() {
        guard demoHasNext else { return }
        demoVisible += 1
        if let snapshot = demoSnapshot() { ingest(snapshot) }
    }

    func demoAsk() {
        guard let snapshot = demoSnapshot() else { return }
        current = snapshot
        run(snapshot, manual: true)
    }

    private func demoSnapshot() -> ConversationSnapshot? {
        let frame = NSApp.windows.first { $0.title == Self.demoWindowTitle && $0.isVisible }?.frame
        return demoScenario?.snapshot(visibleCount: demoVisible, anchor: frame)
    }
}
