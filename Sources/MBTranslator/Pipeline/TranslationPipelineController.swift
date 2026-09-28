import Foundation
import os

enum TranslationPipelineError: Error, LocalizedError {
    case missingCredentials

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            String(localized: "Brak zapisanych danych logowania Azure Speech — uzupełnij klucz i region w Ustawieniach")
        }
    }
}

/// Wires microphone capture → `SpeechTranslationService` together, logs
/// results, and (M2b) feeds them into `SubtitlesState` for the floating
/// subtitles panel. Driven by the existing Start/Stop control in
/// `MenuBarContentView`.
///
/// Logged transcript/translation text intentionally uses `Logger`'s default
/// (private) privacy, not `.public`: visible in Xcode's attached debug
/// console (which de-redacts private values for a live debug session) while
/// still respecting "no conversation content logged in release builds"
/// (only non-content diagnostics use `.public` elsewhere in this codebase).
@MainActor
final class TranslationPipelineController {
    private var task: Task<Void, Never>?
    private let microphoneCapture = MicrophoneCapture()
    private let subtitles: SubtitlesState
    private let appState: AppState
    private let directSpeech = DirectSpeechController()
    private let logger = Logger(subsystem: AppLogging.subsystem, category: "TranslationPipeline")

    var onStatusChange: ((TranslationStatus) -> Void)?

    init(subtitles: SubtitlesState, appState: AppState) {
        self.subtitles = subtitles
        self.appState = appState

        // Never let `MicrophoneCapture`'s and `DirectSpeechPlayer`'s
        // AVAudioEngines run their real-time IO at the same time — see
        // docs/DECISIONS.md, "Follow-up: dwa równoległe silniki audio to za
        // dużo dla tego Maca". Pausing (not stopping) keeps the Azure
        // session's audio-chunk stream alive; `sendLoop` simply stalls
        // waiting for the next chunk for the ~1-3s a clip plays, same as it
        // would during any other brief gap in speech.
        directSpeech.willPlay = { [weak self] in
            self?.microphoneCapture.pause()
        }
        directSpeech.didFinishPlaying = { [weak self] in
            self?.microphoneCapture.resume()
        }
    }

    func start() {
        guard task == nil else { return }
        subtitles.reset()
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        logger.notice("TranslationPipelineController.stop() called")
        task?.cancel()
        task = nil
        microphoneCapture.stop(reason: "TranslationPipelineController.stop()")
        subtitles.reset()
        directSpeech.stop()
    }

    private func run() async {
        do {
            guard let key = try await KeychainStore.shared.load(key: .azureSpeechKey), !key.isEmpty,
                  let region = try await KeychainStore.shared.load(key: .azureSpeechRegion), !region.isEmpty
            else {
                throw TranslationPipelineError.missingCredentials
            }

            let audioStream = try microphoneCapture.start()
            let service = AzureSpeechTranslationService(subscriptionKey: key, region: region)

            for try await event in service.recognize(audioChunks: audioStream, sourceLanguage: "pl-PL", targetLanguage: "en") {
                handle(event)
            }
            // Diagnostic (see docs/DECISIONS.md, "Follow-up: pipeline
            // restartuje się między zdaniami"): this line means the `for
            // await` loop ended *without* throwing — i.e. `recognize()`'s
            // stream finished cleanly, which by design should only happen
            // once the *microphone's own* stream ends. Seeing this fire
            // mid-conversation (not on an intentional Stop) is exactly the
            // evidence needed to pin down why the mic stream ended.
            logger.notice("Pipeline for-loop ended without throwing (recognize() stream finished)")
        } catch is CancellationError {
            logger.notice("Pipeline cancelled (CancellationError)")
        } catch {
            logger.error("Pipeline stopped with error: \(error.localizedDescription, privacy: .public)")
            onStatusChange?(.error(error.localizedDescription))
        }

        microphoneCapture.stop(reason: "run() ended")
        task = nil
    }

    private func handle(_ event: SpeechTranslationEvent) {
        switch event {
        case .sourcePartial(let text):
            logger.info("PL (wersja robocza): \(text)")
        case .sourceFinal(let text):
            logger.notice("PL (finalne): \(text)")
        case .translationPartial(let text):
            logger.info("EN (wersja robocza): \(text)")
        case .translationFinal(let text):
            logger.notice("EN (finalne): \(text)")
            if appState.mode == .speakDirectly {
                // Diagnostic (see docs/DECISIONS.md, "Follow-up: pipeline
                // restartuje się między zdaniami"): confirms whether M3's
                // TTS path is actually engaged during a given repro, since
                // that materially changes the leading theory (DirectSpeechPlayer's
                // second AVAudioEngine vs. something unrelated to M3).
                logger.notice("Mode is speakDirectly — triggering ElevenLabs TTS for this sentence")
                directSpeech.speak(text)
            }
        }
        subtitles.apply(event)
    }
}
