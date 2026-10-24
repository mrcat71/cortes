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
            PrivacySettings(model: model)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 560, height: 430)
        .onAppear { NSApp.activate() }
    }
}

private struct GeneralSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Perspectives") {
                Picker("Perspective mode", selection: $model.perspectiveMode) {
                    ForEach(PerspectiveMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(model.perspectiveMode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Activation", selection: $model.mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            Picker("Auto sensitivity", selection: $model.sensitivity) {
                ForEach(Sensitivity.allCases) { Text($0.title).tag($0) }
            }
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
