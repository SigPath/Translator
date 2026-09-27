import SwiftUI

@main
struct MBTranslatorApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("MB Translator", systemImage: appState.status.systemImage) {
            MenuBarContentView(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
