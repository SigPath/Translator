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
    @State private var pipeline: TranslationPipelineController
    // M2b: the floating subtitles panel and the state feeding it need the
    // same process-lifetime stability as `pipeline` above, for the same
    // reason — and `pipeline` needs a `SubtitlesState` instance to report
    // into. `@State` property initializers can't reference sibling `@State`
    // properties or `self` (not yet fully initialized), so this wiring has
    // to happen in `init()`, assigning the underlying `_property` storage
    // directly — the documented way to give `@State` a computed initial
    // value.
    @State private var subtitles: SubtitlesState
    @State private var subtitlesPanel: SubtitlesPanelController

    init() {
        let subtitles = SubtitlesState()
        _subtitles = State(initialValue: subtitles)
        _pipeline = State(initialValue: TranslationPipelineController(subtitles: subtitles))
        _subtitlesPanel = State(initialValue: SubtitlesPanelController(subtitles: subtitles))
    }

    var body: some Scene {
        MenuBarExtra("MB Translator", systemImage: appState.status.systemImage) {
            MenuBarContentView(appState: appState, pipeline: pipeline, subtitlesPanel: subtitlesPanel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
