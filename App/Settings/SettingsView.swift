import CortesKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelSettings(model: model)
                .tabItem { Label("Model", systemImage: "cpu") }
            AppCaptureSettings(model: model)
                .tabItem { Label("Applications", systemImage: "app.badge") }
            CallSettings(model: model)
                .tabItem { Label("Voice Calls", systemImage: "waveform") }
            PrivacySettings(model: model)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 620, height: 560)
        .onAppear { NSApp.activate() }
    }
}

private struct GeneralSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Picker("Mode", selection: $model.mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            Picker("Auto sensitivity", selection: $model.sensitivity) {
                ForEach(Sensitivity.allCases) { Text($0.title).tag($0) }
            }
            Text("Auto generates suggestions when incoming text changes in an allowed conversation. Every message removes the attention filter. Calls have their own automatic-generation switch.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Hotkey", value: "⌃⌥V asks the voices; press again to dismiss")
            TextField("Your Slack name", text: $model.myNameOverride, prompt: Text("Detected from Slack's sidebar"))
            LabeledContent("Accessibility") {
                if model.axTrusted {
                    Text("Granted").foregroundStyle(.green)
                } else {
                    Button("Grant…") { model.requestAccessibility() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppCaptureSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Read text from other applications") {
                Text("Slack uses its specialized conversation reader. Other apps provide best-effort text context without reliable speaker attribution. Nothing is read from an additional app until you enable it below.")
                    .font(.callout)
                Picker("Text to read", selection: $model.textScope) {
                    ForEach(AppTextScope.allCases) { Text($0.title).tag($0) }
                }
                Text("Selected text is the safest default. Visible window text may include unrelated content; editable fields and password controls are excluded. Allow analysis separately for each context before model generation.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Refresh running applications", action: model.refreshRunningApps)
            }
            Section("Enabled applications") {
                ForEach(applications) { app in
                    Toggle(app.name, isOn: Binding(
                        get: { model.enabledTextApps.contains(app.id) },
                        set: { enabled in
                            if enabled { if !model.enabledTextApps.contains(app.id) { model.enabledTextApps.append(app.id) } }
                            else { model.enabledTextApps.removeAll { $0 == app.id } }
                        }))
                }
                if applications.isEmpty { Text("Open an application, then refresh this list.").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: model.refreshRunningApps)
    }

    private var applications: [CaptureApplication] {
        let running = model.runningApps.filter { $0.id != "com.tinyspeck.slackmacgap" }
        let stopped = model.enabledTextApps.filter { id in !running.contains { $0.id == id } }
            .map { CaptureApplication(id: $0, name: $0 + " (not running)") }
        return running + stopped
    }
}

private struct CallSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Audio-only call assistance") {
                Text("Listens to audio from your chosen app, even during a video call. No camera, screen or video capture. Speech is transcribed on-device; call suggestions always use local Ollama. Audio and transcripts are never saved.")
                    .font(.callout)
                Group {
                    Picker("Call application", selection: $model.callAppID) {
                        Text("Choose an application…").tag("")
                        ForEach(model.runningApps) { Text($0.name).tag($0.id) }
                    }
                    HStack {
                        TextField("Speech language", text: $model.callLocale, prompt: Text("en-US, ru-RU, es-ES"))
                        Button("Refresh apps", action: model.refreshRunningApps)
                    }
                    Toggle("Include my microphone", isOn: $model.callIncludeMicrophone)
                    Text("App audio is labeled Call participants; the microphone is labeled ME. Use headphones to prevent speaker audio being picked up by the microphone. Browsers include audio from all their tabs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(model.callActive || model.callStarting)
                Toggle("Generate suggestions automatically", isOn: $model.callAutoGenerate)
                Text("Requires macOS 26+, permission to capture system audio, and a loopback Ollama URL. Language assets may download on first use. Unsupported languages fail without switching to cloud transcription.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Listening session") {
                Label(model.callStatus, systemImage: model.callActive ? "record.circle.fill" : "waveform")
                    .foregroundStyle(model.callActive ? .red : .secondary)
                    .accessibilityLabel("Call capture status: " + model.callStatus)
                if model.callStarting { ProgressView().controlSize(.small) }
                if model.callActive {
                    Text("\(model.callUtteranceCount) recent utterances in memory. Stop clears the transcript.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Start only with the participants' knowledge and permission. Listening continues if you switch apps, but stops on Pause, sleep, lock or quit. It never restarts automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.callActive || model.callStarting {
                    Button("Stop listening and clear transcript", role: .destructive) { model.stopCall() }
                } else {
                    Button("Start listening", action: model.startCall)
                        .disabled(model.callAppID.isEmpty || model.mode == .paused)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: model.refreshRunningApps)
    }
}

private struct ModelSettings: View {
    @Bindable var model: AppModel
    @State private var keyDraft = ""
    @State private var keyMessage: String?

    var body: some View {
        Form {
            Picker("Where the voices run", selection: $model.engine) {
                ForEach(Engine.allCases) { Text($0.title).tag($0) }
            }
            switch model.engine {
            case .local:
                Section("Local (Ollama)") {
                    TextField("Ollama URL", text: $model.ollamaURL)
                    HStack {
                        TextField("Model", text: $model.ollamaModel)
                        Menu("Pick") {
                            ForEach(AppModel.ollamaModelSuggestions, id: \.self) { name in
                                Button(name) { model.ollamaModel = name }
                            }
                        }
                        .fixedSize()
                    }
                    Text("Runs on this Mac through Ollama; nothing leaves the machine. Download the model once: `ollama pull \(model.ollamaModel)`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Check Ollama") { Task { await model.testConnection() } }
                        Spacer()
                    }
                    if let message = model.connectionTestResult {
                        Text(verbatim: message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .cloud:
                Section("z.ai") {
                    Picker("Endpoint", selection: $model.endpointPreset) {
                        ForEach(EndpointPreset.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("Base URL", text: $model.baseURL)
                    HStack {
                        TextField("Model", text: $model.modelName)
                        Menu("Pick") {
                            ForEach(AppModel.modelSuggestions, id: \.self) { name in
                                Button(name) { model.modelName = name }
                            }
                        }
                        .fixedSize()
                    }
                    Toggle("Disable thinking (faster; dropped automatically if the model refuses)", isOn: $model.disableThinking)
                    Text("A GLM Coding Plan key only works on the Coding Plan endpoint, and z.ai's terms limit that plan to supported coding tools.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("API key") {
                    SecureField("API key", text: $keyDraft, prompt: Text(model.hasAPIKey ? "Saved in Keychain" : "Paste your z.ai API key"))
                    HStack {
                        Button("Save to Keychain") {
                            do {
                                try model.saveAPIKey(keyDraft)
                                keyDraft = ""
                                keyMessage = "Saved."
                            } catch {
                                keyMessage = error.localizedDescription
                            }
                        }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Remove") {
                            do {
                                try model.removeAPIKey()
                                keyMessage = "Removed."
                            } catch {
                                keyMessage = error.localizedDescription
                            }
                        }
                        .disabled(!model.hasAPIKey)
                        Spacer()
                        Button("Test connection") { Task { await model.testConnection() } }
                            .disabled(!model.hasAPIKey)
                    }
                    if let message = model.connectionTestResult ?? keyMessage {
                        Text(verbatim: message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .replay:
                Section("Offline") {
                    Text("Replays a canned answer with no network or model. Last-resort demo fallback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacySettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Text(model.engine == .cloud
                    ? "The voices run on z.ai's cloud. Only conversations on this list are ever sent; the Demo Chat is always allowed. Nothing is stored: conversation state lives in memory and is wiped on pause, sleep and screen lock."
                    : "The voices run locally through Ollama, so nothing ever leaves this Mac. The list below still decides which conversations Cortes reads. Conversation state lives in memory and is wiped on pause, sleep and screen lock.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Replace names with aliases and strip emails, links and phone numbers before prompting", isOn: $model.pseudonymize)
            }
            Section("Allowed conversations") {
                if model.allowlist.isEmpty {
                    Text("None yet. Open a conversation in Slack, then use “Allow analysis” in the menu bar.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.allowlist, id: \.self) { id in
                    HStack {
                        Text(verbatim: id)
                        Spacer()
                        Button {
                            model.allowlist.removeAll { $0 == id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
