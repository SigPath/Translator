import Foundation
import os

enum DirectSpeechControllerError: Error, LocalizedError {
    case noOutputDeviceConfigured

    var errorDescription: String? {
        switch self {
        case .noOutputDeviceConfigured:
            String(localized: "Brak skonfigurowanego urządzenia wyjściowego (VB-Cable) — wybierz je w Ustawieniach → Audio")
        }
    }
}

/// M3: optional "mów bezpośrednio" mode (`AppState.mode == .speakDirectly`).
/// `TranslationPipelineController` calls `speak(_:)` for every `EN
/// (finalne)` translation result — this synthesizes it via ElevenLabs
/// (cloned voice) and plays it back routed to the configured output device
/// (VB-Cable), so the call partner hears synthesized English speech as if
/// from the user's own microphone. Independent of the M2b subtitles panel,
/// which keeps working the same whether or not this mode is on.
///
/// v1 happy path only (per project scope): no mid-utterance interruption or
/// mixing — overlapping utterances play back sequentially, FIFO (see
/// `DirectSpeechPlayer`'s queue).
@MainActor
final class DirectSpeechController {
    private let ttsClient = ElevenLabsTTSClient()
    private let player = DirectSpeechPlayer()
    private let logger = Logger(subsystem: AppLogging.subsystem, category: "DirectSpeechController")
    private var isConfigured = false

    /// Forwarded straight through to `DirectSpeechPlayer` — see its doc
    /// comment. `TranslationPipelineController` wires these to
    /// `MicrophoneCapture.pause()`/`.resume()` so the two engines' IO never
    /// runs concurrently.
    var willPlay: (() -> Void)? {
        get { player.willPlay }
        set { player.willPlay = newValue }
    }
    var didFinishPlaying: (() -> Void)? {
        get { player.didFinishPlaying }
        set { player.didFinishPlaying = newValue }
    }

    func stop() {
        player.stop()
        isConfigured = false
    }

    /// Fire-and-forget: queues synthesis + playback in a background `Task`
    /// without blocking the caller — the pipeline's event loop must keep
    /// processing subsequent recognition events while this runs.
    func speak(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        Task {
            do {
                try ensureConfigured()

                guard let apiKey = try await KeychainStore.shared.load(key: .elevenLabsAPIKey), !apiKey.isEmpty else {
                    logger.error("Brak klucza API ElevenLabs — uzupełnij w Ustawieniach")
                    return
                }
                guard let voiceID = ElevenLabsSettingsStore.shared.voiceID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !voiceID.isEmpty
                else {
                    logger.error("Brak ID głosu ElevenLabs — uzupełnij w Ustawieniach")
                    return
                }

                let audioData = try await ttsClient.synthesize(text: trimmedText, apiKey: apiKey, voiceID: voiceID)
                player.enqueue(audioData)
            } catch {
                logger.error("Tryb 'mów bezpośrednio' nie powiódł się: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Resolves the configured output device once per session and hands it
    /// to `player` — purely synchronous bookkeeping now (the actual engine
    /// is created fresh per clip inside `DirectSpeechPlayer.play(_:)`), so
    /// unlike the old design there's no `await` here and so no way for two
    /// concurrent `speak(_:)` calls to race each other setting this up.
    private func ensureConfigured() throws {
        guard !isConfigured else { return }

        guard let uid = AudioSettingsStore.shared.selectedOutputDeviceUID,
              let device = try AudioDeviceRepository.allDevices().first(where: { $0.uid == uid })
        else {
            throw DirectSpeechControllerError.noOutputDeviceConfigured
        }

        player.configure(deviceID: device.id)
        isConfigured = true
    }
}
