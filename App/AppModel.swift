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
    #if DEBUG
    case replay
    #endif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: "Local (Ollama)"
        case .cloud: "z.ai cloud"
        #if DEBUG
        case .replay: "Replay (offline)"
        #endif
        }
    }
}

enum OverlayPhase {
    case hidden
    case thinking(ConversationKey)
    case streaming(VoiceBatch)
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
    static let bundleID = Bundle.main.bundleIdentifier ?? "io.github.mrcat71.cortes"
    static let keychainAccount = "zai-api-key"
    #if DEBUG
    static let demoWindowTitle = "Demo Chat"
    static let demoWindowID = "demo-chat"
    #endif
    static let modelSuggestions = ["glm-5.2", "glm-5-turbo", "glm-4.7", "glm-4.5-air", "glm-5.3"]
    static let ollamaModelSuggestions = ["gemma4:12b", "gemma4:26b", "gemma4:e4b", "gemma4:12b-mlx"]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let log = Logger(subsystem: AppModel.bundleID, category: "app")

    // MARK: Settings (UserDefaults; the API key lives in Keychain)

    var mode: Mode { didSet { defaults.set(mode.rawValue, forKey: "mode"); applyMode() } }
    var perspectiveMode: PerspectiveMode {
        didSet {
            guard oldValue != perspectiveMode else { return }
            defaults.set(perspectiveMode.rawValue, forKey: "perspectiveMode")
            cancelWork()
            hideOverlay()
            copiedVoiceID = nil
            firedRevisions.removeAll()
            lastFire.removeAll()
            lastGlobalFire = .distantPast
            recentTop.removeAll()
            voices = VoiceRegistry.load(mode: perspectiveMode)
            if started, engine == .local { warmUpLocalModel() }
        }
    }
    var sensitivity: Sensitivity { didSet { defaults.set(sensitivity.rawValue, forKey: "sensitivity") } }
    var baseURL: String { didSet { defaults.set(baseURL, forKey: "baseURL") } }
    var modelName: String { didSet { defaults.set(modelName, forKey: "model") } }
    var disableThinking: Bool { didSet { defaults.set(disableThinking, forKey: "disableThinking") } }
    var pseudonymize: Bool { didSet { defaults.set(pseudonymize, forKey: "pseudonymize") } }
    var engine: Engine { didSet { defaults.set(engine.rawValue, forKey: "engine") } }
    var ollamaURL: String {
        didSet {
            defaults.set(ollamaURL, forKey: "ollamaURL")
            if callSessionID != nil, !CapturePrivacy.isLoopback(ollamaURL) { stopCall() }
        }
    }
    var ollamaModel: String { didSet { defaults.set(ollamaModel, forKey: "ollamaModel") } }
    var enabledTextApps: [String] {
        didSet {
            defaults.set(enabledTextApps, forKey: "enabledTextApps")
            capture?.configure(apps: enabledTextApps, scope: textScope)
            if let current, current.kind == .context, !enabledTextApps.contains(current.key.app) { leaveConversation() }
        }
    }
    var textScope: AppTextScope {
        didSet {
            defaults.set(textScope.rawValue, forKey: "textScope")
            capture?.configure(apps: enabledTextApps, scope: textScope)
            if current?.kind == .context { leaveConversation() }
        }
    }
    var callAppID: String { didSet { defaults.set(callAppID, forKey: "callAppID") } }
    var callLocale: String { didSet { defaults.set(callLocale, forKey: "callLocale") } }
    var callIncludeMicrophone: Bool { didSet { defaults.set(callIncludeMicrophone, forKey: "callIncludeMicrophone") } }
    var callAutoGenerate: Bool { didSet { defaults.set(callAutoGenerate, forKey: "callAutoGenerate") } }
    var myNameOverride: String {
        didSet {
            defaults.set(myNameOverride, forKey: "myName")
            capture?.setMyNameOverride(myNameOverride.isEmpty ? nil : myNameOverride)
        }
    }
    var allowlist: [String] {
        didSet {
            defaults.set(allowlist, forKey: "allowlist")
            if let current, !isAllowed(current.key) { cancelWork(); hideOverlay() }
        }
    }
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
    #if DEBUG
    var demoScenarioID: String { didSet { demoReset() } }
    private(set) var demoVisible = 0
    #endif
    private(set) var runningApps: [CaptureApplication] = []
    private(set) var callActive = false
    private(set) var callStarting = false
    private(set) var callStatus = "Not listening"
    private(set) var callUtteranceCount = 0

    private(set) var voices: [VoiceDefinition]
    #if DEBUG
    let scenarios: [Scenario]
    #endif

    @ObservationIgnored private var overlay: OverlayController?
    @ObservationIgnored private var capture: TextCaptureSource?
    @ObservationIgnored private var callCapture: (any VoiceCaptureSession)?
    @ObservationIgnored private var callStartTask: Task<Void, Never>?
    @ObservationIgnored private var callSessionID: UUID?
    @ObservationIgnored private var callTranscript: CallTranscript?
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
    @ObservationIgnored private var screenLocked = false
    @ObservationIgnored private var sleeping = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .manual
        let perspectiveMode = PerspectiveMode(rawValue: defaults.string(forKey: "perspectiveMode") ?? "") ?? .innerVoices
        self.perspectiveMode = perspectiveMode
        sensitivity = Sensitivity(rawValue: defaults.string(forKey: "sensitivity") ?? "") ?? .medium
        baseURL = defaults.string(forKey: "baseURL") ?? ZAIEndpoint.general
        modelName = defaults.string(forKey: "model") ?? "glm-5.2"
        disableThinking = defaults.object(forKey: "disableThinking") as? Bool ?? true
        pseudonymize = defaults.object(forKey: "pseudonymize") as? Bool ?? true
        #if DEBUG
        // First migration step from the old replay toggle; afterwards the engine key wins.
        engine = Engine(rawValue: defaults.string(forKey: "engine") ?? "")
            ?? (defaults.bool(forKey: "useReplay") ? .replay : .local)
        #else
        engine = Engine(rawValue: defaults.string(forKey: "engine") ?? "") ?? .local
        #endif
        ollamaURL = defaults.string(forKey: "ollamaURL") ?? OllamaConfig.defaultURL
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? OllamaConfig.defaultModel
        enabledTextApps = defaults.stringArray(forKey: "enabledTextApps") ?? []
        textScope = AppTextScope(rawValue: defaults.string(forKey: "textScope") ?? "") ?? .selection
        callAppID = defaults.string(forKey: "callAppID") ?? ""
        callLocale = defaults.string(forKey: "callLocale") ?? "en-US"
        callIncludeMicrophone = defaults.bool(forKey: "callIncludeMicrophone")
        callAutoGenerate = defaults.object(forKey: "callAutoGenerate") as? Bool ?? true
        myNameOverride = defaults.string(forKey: "myName") ?? ""
        allowlist = defaults.stringArray(forKey: "allowlist") ?? []
        voices = VoiceRegistry.load(mode: perspectiveMode)
        #if DEBUG
        scenarios = Scenario.loadBundled()
        demoScenarioID = scenarios.first?.id ?? ""
        #endif
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
        let source = TextCaptureSource { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        source.setMyNameOverride(myNameOverride.isEmpty ? nil : myNameOverride)
        source.setMyNameFallback(defaults.string(forKey: "detectedSlackName"))
        source.configure(apps: enabledTextApps, scope: textScope)
        capture = source
        observeSystem()
        if !axTrusted { pollTrust() }
        #if DEBUG
        demoReset()
        #endif
        applyMode()
        if engine == .local { warmUpLocalModel() }
    }

    /// Loads the model and caches the system prompt's prefix right after launch, so the first real
    /// request only pays generation time. Ollama keeps it resident for the configured keep-alive.
    private func warmUpLocalModel() {
        let backend = OllamaBackend(config: OllamaConfig(baseURL: ollamaURL, model: ollamaModel))
        let system = PromptBuilder.system(voices: voices.filter(\.enabled), perspectiveMode: perspectiveMode)
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
        if callActive || callStarting { return "waveform.circle.fill" }
        if !axTrusted { return "exclamationmark.triangle" }
        switch phase {
        case .thinking, .streaming: return "ellipsis.bubble"
        default: break
        }
        return mode == .auto ? "brain" : "brain.head.profile"
    }

    var endpointPreset: EndpointPreset {
        get { EndpointPreset.allCases.first { $0.url == baseURL } ?? .custom }
        set { if let url = newValue.url { baseURL = url } }
    }

    func isAllowed(_ key: ConversationKey) -> Bool {
        #if DEBUG
        if key.app == "demo" { return true }
        #endif
        if key == callTranscript?.key { return true }
        return (key.app == "slack" || enabledTextApps.contains(key.app)) && allowlist.contains(key.id)
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
        if mode == .paused || screenLocked || sleeping {
            capture?.stop()
            wipe()
            captureStatus = mode == .paused ? "Paused" : "Capture suspended"
        } else if callSessionID == nil {
            capture?.start()
        }
    }

    private func handle(_ event: CaptureEvent) {
        guard mode != .paused, !screenLocked, !sleeping, callSessionID == nil else { return }
        switch event {
        case .notTrusted:
            if axTrusted { log.notice("Accessibility trust lost") }
            axTrusted = false
            captureStatus = "Accessibility permission needed"
        case .inactive(let reason):
            captureStatus = reason
            if current?.key.app != "demo" { leaveConversation() }
        case .failed(let message):
            captureStatus = message
            if current?.key.app != "demo" { leaveConversation() }
        case .snapshot(let snapshot):
            guard CapturePrivacy.allowsTextContext(snapshot, apps: enabledTextApps, scope: textScope) else { return }
            if !axTrusted { log.notice("Accessibility trusted; reading application text") }
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
        if automaticGenerationEnabled { scheduleAuto() }
    }

    private func leaveConversation() {
        current = nil
        cancelWork()
        hideOverlay()
    }

    private func wipe() {
        stopCall(resumeTextCapture: false)
        current = nil
        firedRevisions.removeAll()
        lastFire.removeAll()
        recentTop.removeAll()
        cancelWork()
        hideOverlay()
    }

    // MARK: Triggers

    private var automaticGenerationEnabled: Bool {
        mode != .paused && !screenLocked && !sleeping && (callSessionID != nil ? callAutoGenerate : mode == .auto)
    }

    private func scheduleAuto() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.autoFire()
        }
    }

    private func autoFire() {
        guard automaticGenerationEnabled, let snapshot = current, isAllowed(snapshot.key), !overlayHovered,
              inflight == nil else { return }
        guard let last = snapshot.messages.last, !last.isMe else { return }
        guard !firedRevisions.contains(snapshot.key.id + "#" + snapshot.revision) else { return }
        let now = Date()
        let sensitivity = snapshot.kind == .call ? Sensitivity.every : self.sensitivity
        guard now.timeIntervalSince(lastFire[snapshot.key.id] ?? .distantPast) > sensitivity.conversationCooldown,
              now.timeIntervalSince(lastGlobalFire) > sensitivity.globalCooldown
        else { return }
        guard TriggerPolicy.attentionScore(snapshot) >= sensitivity.threshold else { return }
        run(snapshot, manual: false)
    }

    func hotKeyPressed() {
        guard mode != .paused, !screenLocked, !sleeping else {
            captureStatus = mode == .paused ? "Paused" : "Capture suspended"
            return
        }
        if callActive {
            if let current, !current.messages.isEmpty { run(current, manual: true) }
            return
        }
        if callStarting { return }
        #if DEBUG
        if NSApp.isActive, NSApp.keyWindow?.title == Self.demoWindowTitle {
            demoAsk()
            return
        }
        #endif
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
                case .notTrusted: self.showFailure("Cortes needs Accessibility permission to read application text.")
                case .failed(let message), .inactive(let message): self.showFailure(message)
                }
            }
        }
    }

    // MARK: Generation

    func run(_ snapshot: ConversationSnapshot, manual: Bool) {
        guard callSessionID == nil || snapshot.kind == .call else { return }
        cancelWork()
        guard mode != .paused, !screenLocked, !sleeping else { return }
        guard CapturePrivacy.allowsTextContext(snapshot, apps: enabledTextApps, scope: textScope) else {
            showFailure("This app or text capture scope is no longer enabled.")
            return
        }
        guard isAllowed(snapshot.key) else {
            if manual {
                phase = .consent(snapshot)
                showOverlay(anchor: snapshot.anchorFrame)
            }
            return
        }
        let backend: any LLMBackend
        if snapshot.kind == .call {
            guard callActive, snapshot.key == callTranscript?.key, CapturePrivacy.isLoopback(ollamaURL) else {
                showFailure("Call analysis requires an active session and a loopback Ollama URL.")
                return
            }
            do {
                backend = try OllamaBackend.localOnly(config: OllamaConfig(baseURL: ollamaURL, model: ollamaModel))
            } catch {
                showFailure(error.localizedDescription)
                return
            }
        } else {
            switch engine {
            #if DEBUG
            case .replay:
                backend = ReplayBackend(perspectiveMode: perspectiveMode)
            #endif
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
        }
        firedRevisions.insert(snapshot.key.id + "#" + snapshot.revision)
        lastFire[snapshot.key.id] = Date()
        lastGlobalFire = Date()
        stale = false
        phase = .thinking(snapshot.key)
        showOverlay(anchor: snapshot.anchorFrame)

        let engine = SuggestionEngine(
            backend: backend, voices: voices.filter(\.enabled), recentTop: recentTop, perspectiveMode: perspectiveMode)
        let request = SuggestionRequest(snapshot: snapshot, mode: manual ? "manual" : "auto", pseudonymize: pseudonymize)
        inflight = Task { [weak self] in
            do {
                let result = try await engine.run(request) { [weak self] batch in
                    guard !Task.isCancelled else { return }
                    await self?.showProgress(batch, snapshot: snapshot)
                }
                guard !Task.isCancelled, let self else { return }
                self.inflight = nil
                self.finish(result, auto: !manual)
                self.schedulePendingAuto(after: snapshot)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.inflight = nil
                self.log.error("Generation failed: \(error.localizedDescription, privacy: .public)")
                self.phase = .failure(error.localizedDescription)
                self.schedulePendingAuto(after: snapshot)
            }
        }
    }

    private func showProgress(_ batch: VoiceBatch?, snapshot: ConversationSnapshot) {
        guard !Task.isCancelled, current?.key == snapshot.key else { return }
        stale = current?.revision != snapshot.revision
        phase = batch.map(OverlayPhase.streaming) ?? .thinking(snapshot.key)
    }

    private func schedulePendingAuto(after snapshot: ConversationSnapshot) {
        if automaticGenerationEnabled, let current, current.key == snapshot.key, current.revision != snapshot.revision {
            scheduleAuto()
        }
    }

    // MARK: Additional applications and audio-only calls

    func refreshRunningApps() {
        runningApps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != Self.bundleID else {
                return nil
            }
            return CaptureApplication(id: id, name: app.localizedName ?? id)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func startCall() {
        guard callSessionID == nil, mode != .paused, !screenLocked, !sleeping else { return }
        guard #available(macOS 26, *) else { callStatus = "Voice calls require macOS 26 or later."; return }
        guard CapturePrivacy.isLoopback(ollamaURL) else {
            callStatus = "Use a loopback Ollama URL for private call analysis."; return
        }
        refreshRunningApps()
        guard let app = runningApps.first(where: { $0.id == callAppID }) else {
            callStatus = "Select the app hosting your call."; return
        }
        cancelWork()
        hideOverlay()
        capture?.stop()
        let id = UUID()
        callSessionID = id
        callTranscript = CallTranscript(sessionID: id, appName: app.name)
        current = callTranscript?.snapshot
        callUtteranceCount = 0
        callStarting = true
        callStatus = "Checking the local voice model…"
        let session = VoiceCallCapture()
        callCapture = session
        let locale = Locale(identifier: callLocale)
        let includeMicrophone = callIncludeMicrophone
        let modelConfig = OllamaConfig(baseURL: ollamaURL, model: ollamaModel)
        callStartTask = Task { [weak self] in
            do {
                try await OllamaBackend.localOnly(config: modelConfig).verifyLocalModel()
                try Task.checkCancellation()
                try await session.start(
                    bundleID: app.id, locale: locale, includeMicrophone: includeMicrophone,
                    onText: { [weak self] text, isMe in
                        Task { @MainActor in self?.receiveCallText(text, isMe: isMe, sessionID: id) }
                    },
                    onError: { [weak self] message in
                        Task { @MainActor in
                            guard let self, self.callSessionID == id else { return }
                            self.stopCall()
                            self.callStatus = "Listening stopped: " + message
                        }
                    }, onStatus: { [weak self] message in
                        Task { @MainActor in
                            guard let self, self.callSessionID == id, self.callStarting else { return }
                            self.callStatus = message
                        }
                    })
                try Task.checkCancellation()
                guard let self, self.callSessionID == id else { session.stop(); return }
                self.callStarting = false
                self.callActive = true
                self.callStatus =
                    "Listening to \(app.name)\(includeMicrophone ? " and microphone" : "") · audio only · local"
                self.callStartTask = nil
            } catch {
                session.stop()
                guard let self, self.callSessionID == id else { return }
                self.stopCall()
                self.callStatus = "Listening stopped: " + error.localizedDescription
            }
        }
    }

    private func receiveCallText(_ text: String, isMe: Bool, sessionID: UUID) {
        guard callActive, callSessionID == sessionID else { return }
        callTranscript?.append(text, isMe: isMe)
        callUtteranceCount = callTranscript?.messages.count ?? 0
        if let snapshot = callTranscript?.snapshot { ingest(snapshot) }
    }

    func stopCall(resumeTextCapture: Bool = true) {
        let wasListening = callSessionID != nil
        callSessionID = nil
        callStartTask?.cancel()
        callStartTask = nil
        callCapture?.stop()
        callCapture = nil
        callActive = false
        callStarting = false
        callTranscript = nil
        callUtteranceCount = 0
        if wasListening {
            cancelWork()
            hideOverlay()
            current = nil
            firedRevisions = firedRevisions.filter { !$0.hasPrefix("call:") }
            lastFire = lastFire.filter { !$0.key.hasPrefix("call:") }
            recentTop.removeAll()
            callStatus = "Not listening; transcript cleared"
            if resumeTextCapture, mode != .paused, !screenLocked, !sleeping { capture?.start() }
        }
    }

    private func finish(_ result: SuggestionResult, auto: Bool) {
        if let current, current.key != result.key { return }  // the user moved on: drop it
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
        #if DEBUG
        case .replay:
            connectionTestResult = "Replay answers from a canned response; no connection needed."
        #endif
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
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.stopCall(resumeTextCapture: false) } })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = true; self?.applyMode() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = false; self?.applyMode() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked = true; self?.applyMode() }
        })
        // Only text capture resumes after wake/unlock. Audio sessions always require a new Start.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked = false; self?.applyMode() }
        })
        #if DEBUG
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
        #endif
    }

    #if DEBUG
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
    #endif
}
