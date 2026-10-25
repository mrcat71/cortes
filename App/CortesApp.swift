import SwiftUI

@main
struct CortesApp: App {
    @State private var model: AppModel

    init() {
        if CommandLine.arguments.contains("--self-test") {
            ReleaseSmoke.run()
        }
        let model = AppModel()
        _model = State(initialValue: model)
        // Start after the run loop is up, so the panel and hotkey are created inside a running app.
        DispatchQueue.main.async {
            model.start()
            AppUpdater.shared.start()
        }
    }

    var body: some Scene {
        MenuBarExtra("Cortes", systemImage: model.menuBarSymbol) {
            MenuContent(model: model)
        }

        #if DEBUG
        Window(AppModel.demoWindowTitle, id: AppModel.demoWindowID) {
            DemoChatView(model: model)
        }
        .defaultSize(width: 520, height: 640)
        // `open Cortes.app --args --demo` starts with the Demo Chat open, for demo prep.
        .defaultLaunchBehavior(CommandLine.arguments.contains("--demo") ? .presented : .suppressed)
        #endif

        Settings {
            SettingsView(model: model)
        }
    }
}

struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.captureStatus)
        if model.callActive || model.callStarting {
            Label(model.callStatus, systemImage: "record.circle.fill")
            Button("Stop listening and clear transcript", role: .destructive) { model.stopCall() }
        }
        Divider()
        Button("Ask the voices  ⌃⌥V") { model.hotKeyPressed() }
        Picker("Mode", selection: $model.mode) {
            ForEach(Mode.allCases) { Text($0.title).tag($0) }
        }
        if let key = model.current?.key, key.app != "demo", model.current?.kind != .call {
            Toggle(
                model.engine == .cloud ? "Allow cloud analysis: \(key.title)" : "Allow analysis: \(key.title)",
                isOn: Binding(get: { model.isAllowed(key) }, set: { model.setAllowed(key, $0) }))
        }
        Divider()
        #if DEBUG
        Button("Demo Chat…") {
            openWindow(id: AppModel.demoWindowID)
            NSApp.activate()
        }
        #endif
        if !model.axTrusted {
            Button("Grant Accessibility…") { model.requestAccessibility() }
        }
        SettingsLink { Text("Settings…") }
        Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
            .disabled(!AppUpdater.shared.canCheckForUpdates)
        Divider()
        Button("Quit Cortes") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
