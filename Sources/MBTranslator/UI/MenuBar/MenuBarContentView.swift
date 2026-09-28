import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @Bindable var appState: AppState
    let pipeline: TranslationPipelineController
    @Environment(\.openSettings) private var openSettings

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
        if appState.isRunning {
            pipeline.stop()
            appState.isRunning = false
            appState.status = .idle
        } else {
            pipeline.onStatusChange = { [weak appState] status in
                appState?.status = status
                appState?.isRunning = false
            }
            appState.isRunning = true
            appState.status = .translating
            pipeline.start()
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
