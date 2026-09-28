import AppKit
import SwiftUI
import os

struct MenuBarContentView: View {
    @Bindable var appState: AppState
    let pipeline: TranslationPipelineController
    let subtitlesPanel: SubtitlesPanelController
    @Environment(\.openSettings) private var openSettings
    private let logger = Logger(subsystem: AppLogging.subsystem, category: "MenuBarContentView")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(appState.status.label, systemImage: appState.status.systemImage)
                .font(.headline)

            Divider()

            Button(startStopLabel, action: toggleRunning)

            Picker("Tryb", selection: $appState.mode) {
                ForEach(TranslationMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.inline)

            Divider()

            HStack {
                Text("Opóźnienie")
                Spacer()
                Text(latencyText)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Ustawienia…") {
                openSettingsWindow()
            }

            Button("Zamknij MB Translator") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private var startStopLabel: String {
        appState.isRunning ? String(localized: "Zatrzymaj") : String(localized: "Start")
    }

    private var latencyText: String {
        appState.latencyMilliseconds.map { "\($0) ms" } ?? "—"
    }

    private func toggleRunning() {
        // Diagnostic (see docs/DECISIONS.md, "Follow-up: tajemniczy
        // Zatrzymaj zaraz po wznowieniu mikrofonu"): a real button tap is
        // always dispatched from within AppKit's handling of a genuine
        // `NSEvent` — logging it here (type/location/timestamp) is the
        // most direct way to tell a real click from something else (a
        // stale/replayed event, an accessibility-synthesized action, or
        // anything else with no normal event behind it) reaching this same
        // action closure.
        let eventDescription: String
        if let event = NSApp.currentEvent {
            eventDescription = "type=\(event.type.rawValue) subtype=\(event.subtype.rawValue) locationInWindow=\(String(describing: event.locationInWindow)) timestamp=\(event.timestamp) window=\(event.window?.title ?? "nil")"
        } else {
            eventDescription = "NSApp.currentEvent is nil"
        }
        logger.notice("toggleRunning() tapped, appState.isRunning was \(appState.isRunning, privacy: .public), triggering event: \(eventDescription, privacy: .public)")
        if appState.isRunning {
            // `pipeline.stop()` can refuse a suspected-spurious call (see
            // its doc comment) — only follow through on the UI side when it
            // actually stopped, or the button/panel would show "stopped"
            // while the pipeline keeps running underneath.
            guard pipeline.stop() else { return }
            appState.isRunning = false
            appState.status = .idle
            subtitlesPanel.hide()
        } else {
            pipeline.onStatusChange = { [weak appState, subtitlesPanel] status in
                appState?.status = status
                appState?.isRunning = false
                subtitlesPanel.hide()
            }
            appState.isRunning = true
            appState.status = .translating
            pipeline.start()
            subtitlesPanel.show()
        }
    }

    /// `SettingsLink`/`openSettings()` alone are unreliable from a
    /// MenuBarExtra in an `LSUIElement` (accessory, no Dock icon) app: the
    /// Settings scene can be requested without the app itself becoming
    /// active, so the window never visibly comes to front. Documented,
    /// long-standing SwiftUI/AppKit limitation (Apple Developer Forums
    /// thread 731628, FB10184971), not specific to this app — the fix is to
    /// explicitly activate the app first.
    private func openSettingsWindow() {
        NSApplication.shared.activate()
        openSettings()
    }
}
