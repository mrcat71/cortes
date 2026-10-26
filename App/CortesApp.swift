import SwiftUI

@main
struct CortesApp: App {
    @State private var model: AppModel

    init() {
        #if DEBUG
        if CommandLine.arguments.contains("--interaction-self-test") { InteractionSmoke.run() }
        #endif
        if CommandLine.arguments.contains("--self-test") {
            ReleaseSmoke.run()
        }
        let model = AppModel()
        NSApplication.shared.setActivationPolicy(model.showMenuBarIcon ? .accessory : .regular)
        _model = State(initialValue: model)
        // Start after the run loop is up, so the panel and hotkey are created inside a running app.
        DispatchQueue.main.async {
            model.start()
            AppUpdater.shared.start()
        }
    }

    var body: some Scene {
        MenuBarExtra("Cortes", systemImage: model.menuBarSymbol, isInserted: $model.showMenuBarIcon) {
            MenuContent(model: model)
                .environment(\.locale, model.language.locale)
        }

        Window("Cortes", id: "controls") {
            SettingsView(model: model)
                .environment(\.locale, model.language.locale)
        }
        .defaultLaunchBehavior(model.showMenuBarIcon ? .suppressed : .presented)
        .restorationBehavior(.disabled)

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
                .environment(\.locale, model.language.locale)
        }
    }
}

struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.displayCaptureStatus)
        if model.callActive || model.callStarting {
            Label(model.localized(model.callStatus), systemImage: "record.circle.fill")
            Button("Stop listening and clear transcript", role: .destructive) { model.stopCall() }
        }
        Divider()
        Button("Ask the voices  ⌃⌥V") { model.hotKeyPressed() }
        Picker("Mode", selection: $model.mode) {
            ForEach(Mode.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
        }
        if let key = model.current?.key, key.app != "demo", model.current?.kind != .call {
            Toggle(
                model.localized(model.engine == .cloud ? "Allow cloud analysis: %@" : "Allow analysis: %@", key.title),
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
