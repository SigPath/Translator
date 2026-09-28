import SwiftUI

@main
struct MBTranslatorApp: App {
    @State private var appState = AppState()
    // Owned here, not by MenuBarContentView: a MenuBarExtra's content view
    // (especially `.window` style) is commonly torn down and recreated each
    // time the popover closes/reopens, which would deallocate a `@State`
    // held there mid-session - killing the running mic/WebSocket pipeline
    // silently. The App struct itself has one stable instance for the whole
    // process lifetime, so `@State` here actually persists. See
    // docs/DECISIONS.md.
    @State private var pipeline = TranslationPipelineController()

    var body: some Scene {
        MenuBarExtra("MB Translator", systemImage: appState.status.systemImage) {
            MenuBarContentView(appState: appState, pipeline: pipeline)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
