import SwiftUI

@main
struct MBTranslatorApp: App {
    // Owned here, not by MenuBarContentView: a MenuBarExtra's content view
    // (especially `.window` style) is commonly torn down and recreated each
    // time the popover closes/reopens, which would deallocate a `@State`
    // held there mid-session - killing the running mic/WebSocket pipeline
    // silently. The App struct itself has one stable instance for the whole
    // process lifetime, so `@State` here actually persists. See
    // docs/DECISIONS.md.
    //
    // `appState` moved into `init()` alongside the others (M3): `pipeline`
    // now needs the same `AppState` instance MenuBarContentView binds to, to
    // read `mode` (`.speakDirectly`) when deciding whether to trigger the
    // ElevenLabs "mów bezpośrednio" path. `@State` property initializers
    // can't reference sibling `@State` properties or `self` (not yet fully
    // initialized), so this wiring happens in `init()`, assigning the
    // underlying `_property` storage directly — the documented way to give
    // `@State` a computed initial value.
    @State private var appState: AppState
    @State private var pipeline: TranslationPipelineController
    @State private var incoming: IncomingTranslationController
    @State private var subtitles: SubtitlesState
    @State private var subtitlesPanel: SubtitlesPanelController

    init() {
        let appState = AppState()
        let subtitles = SubtitlesState()
        _appState = State(initialValue: appState)
        _subtitles = State(initialValue: subtitles)
        _pipeline = State(initialValue: TranslationPipelineController(subtitles: subtitles, appState: appState))
        _incoming = State(initialValue: IncomingTranslationController(subtitles: subtitles))
        _subtitlesPanel = State(initialValue: SubtitlesPanelController(subtitles: subtitles))
    }

    var body: some Scene {
        MenuBarExtra("MB Translator", systemImage: appState.status.systemImage) {
            MenuBarContentView(appState: appState, pipeline: pipeline, incoming: incoming, subtitlesPanel: subtitlesPanel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
