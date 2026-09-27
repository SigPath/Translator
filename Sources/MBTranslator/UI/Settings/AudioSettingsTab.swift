import CoreAudio
import SwiftUI

struct AudioSettingsTab: View {
    @State private var outputDevices: [AudioDevice] = []
    @State private var selectedDeviceID: AudioDeviceID?
    @State private var loadErrorMessage: String?
    @State private var playbackErrorMessage: String?
    @State private var isPlaying = false
    @State private var autoDetectedVBCable = false

    private let player = TestTonePlayer()
    private let settingsStore = AudioSettingsStore.shared

    var body: some View {
        Form {
            Section("Urządzenie wyjściowe (wirtualny mikrofon)") {
                if let loadErrorMessage {
                    Text(loadErrorMessage).foregroundStyle(.red)
                } else if outputDevices.isEmpty {
                    ProgressView()
                } else {
                    Picker("Urządzenie", selection: $selectedDeviceID) {
                        ForEach(outputDevices) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedDeviceID) { _, newValue in
                        selectionChanged(to: newValue)
                    }

                    if autoDetectedVBCable {
                        Label("Automatycznie wykryto VB-Cable", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }

                    HStack {
                        Button(isPlaying ? "Odtwarzanie…" : "Odtwórz plik testowy") {
                            playTestTone()
                        }
                        .disabled(selectedDeviceID == nil || isPlaying)

                        if let playbackErrorMessage {
                            Label(playbackErrorMessage, systemImage: "xmark.octagon.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }

                    Text("Ustaw to samo urządzenie jako mikrofon w komunikatorze (Teams/WhatsApp/Zoom), aby rozmówca usłyszał plik testowy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .task {
            await loadDevices()
        }
    }

    private func loadDevices() async {
        do {
            let devices = try AudioDeviceRepository.allDevices().filter(\.hasOutput)
            outputDevices = devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            if let storedUID = settingsStore.selectedOutputDeviceUID,
               let match = outputDevices.first(where: { $0.uid == storedUID }) {
                selectedDeviceID = match.id
            } else if let vbCable = outputDevices.first(where: \.looksLikeVBCable) {
                selectedDeviceID = vbCable.id
                autoDetectedVBCable = true
                settingsStore.selectedOutputDeviceUID = vbCable.uid
            } else {
                selectedDeviceID = outputDevices.first?.id
            }
        } catch {
            loadErrorMessage = String(localized: "Nie udało się pobrać listy urządzeń audio")
        }
    }

    private func selectionChanged(to deviceID: AudioDeviceID?) {
        autoDetectedVBCable = false
        guard let deviceID, let device = outputDevices.first(where: { $0.id == deviceID }) else { return }
        settingsStore.selectedOutputDeviceUID = device.uid
    }

    private func playTestTone() {
        guard let selectedDeviceID else { return }
        playbackErrorMessage = nil
        isPlaying = true
        do {
            try player.play(deviceID: selectedDeviceID)
        } catch {
            playbackErrorMessage = error.localizedDescription
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            isPlaying = false
        }
    }
}
