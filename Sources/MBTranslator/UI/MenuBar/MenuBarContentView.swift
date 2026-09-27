import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @Bindable var appState: AppState

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

            Picker("Komunikator", selection: $appState.selectedConversationApp) {
                ForEach(ConversationApp.allCases) { app in
                    Text(app.label).tag(app)
                }
            }

            Divider()

            HStack {
                Text("Opóźnienie")
                Spacer()
                Text(latencyText)
                    .foregroundStyle(.secondary)
            }

            Divider()

            SettingsLink {
                Text("Ustawienia…")
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
        appState.isRunning.toggle()
        appState.status = appState.isRunning ? .translating : .idle
    }
}
