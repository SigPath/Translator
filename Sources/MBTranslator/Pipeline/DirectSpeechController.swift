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
    private var isStarted = false
    private var startTask: Task<Void, Error>?

    func stop() {
        startTask?.cancel()
        startTask = nil
        player.stop()
        isStarted = false
    }

    /// Fire-and-forget: queues synthesis + playback in a background `Task`
    /// without blocking the caller — the pipeline's event loop must keep
    /// processing subsequent recognition events while this runs.
    func speak(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        Task {
            do {
                try await ensureStarted()

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

    /// Lazily brings up the VB-Cable-routed playback engine on first use,
    /// rather than unconditionally at pipeline start — most sessions won't
    /// use this optional mode at all.
    ///
    /// Two `EN (finalne)` events arriving close together each spawn their
    /// own `Task` in `speak(_:)`, so two calls here can interleave on the
    /// main actor before either finishes. Without sharing the in-flight
    /// attempt, the second call would see `isStarted == false` too and call
    /// `player.start(deviceID:)` again — which tears down the first call's
    /// still-starting engine via its own `stop()`. Stashing the task and
    /// having concurrent callers await the same one avoids that.
    private func ensureStarted() async throws {
        guard !isStarted else { return }

        if let startTask {
            try await startTask.value
            return
        }

        let task = Task<Void, Error> {
            guard let uid = AudioSettingsStore.shared.selectedOutputDeviceUID,
                  let device = try AudioDeviceRepository.allDevices().first(where: { $0.uid == uid })
            else {
                throw DirectSpeechControllerError.noOutputDeviceConfigured
            }
            try await self.player.start(deviceID: device.id)
        }
        startTask = task

        do {
            try await task.value
            isStarted = true
            startTask = nil
        } catch {
            startTask = nil
            throw error
        }
    }
}
