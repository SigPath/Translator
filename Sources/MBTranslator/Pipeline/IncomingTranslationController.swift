import Foundation
import os

/// M4 "tor B": Teams audio (remote party, English) → Azure → Polish
/// subtitles on the right half of the panel. Independent of
/// `TranslationPipelineController` (the user's own microphone, PL → EN):
/// separate start/stop, its own Azure session, no TTS — subtitles only.
///
/// Logged text intentionally uses `Logger`'s default (private) privacy, same
/// as `TranslationPipelineController`.
@MainActor
final class IncomingTranslationController {
    private var task: Task<Void, Never>?
    private let tapCapture = ProcessTapCapture()
    private let subtitles: SubtitlesState
    private let logger = Logger(subsystem: AppLogging.subsystem, category: "IncomingTranslation")

    var onStatusChange: ((TranslationStatus) -> Void)?

    init(subtitles: SubtitlesState) {
        self.subtitles = subtitles
    }

    func start() {
        guard task == nil else { return }
        subtitles.resetIncoming()
        subtitles.isIncomingActive = true
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        logger.notice("IncomingTranslationController.stop() called")
        task?.cancel()
        task = nil
        tapCapture.stop(reason: "IncomingTranslationController.stop()")
        subtitles.isIncomingActive = false
        subtitles.resetIncoming()
    }

    private func run() async {
        do {
            guard let key = try await KeychainStore.shared.load(key: .azureSpeechKey), !key.isEmpty,
                  let region = try await KeychainStore.shared.load(key: .azureSpeechRegion), !region.isEmpty
            else {
                throw TranslationPipelineError.missingCredentials
            }

            let processIDs = TeamsProcessLocator.teamsAudioProcessObjectIDs()
            let audioStream = try tapCapture.start(processObjectIDs: processIDs)
            let service = AzureSpeechTranslationService(subscriptionKey: key, region: region)

            for try await event in service.recognize(audioChunks: audioStream, sourceLanguage: "en-US", targetLanguage: "pl") {
                handle(event)
            }
            logger.notice("Incoming pipeline for-loop ended without throwing (recognize() stream finished)")
        } catch is CancellationError {
            logger.notice("Incoming pipeline cancelled (CancellationError)")
        } catch {
            logger.error("Incoming pipeline stopped with error: \(error.localizedDescription, privacy: .public)")
            onStatusChange?(.error(error.localizedDescription))
        }

        tapCapture.stop(reason: "run() ended")
        subtitles.isIncomingActive = false
        task = nil
    }

    private func handle(_ event: SpeechTranslationEvent) {
        switch event {
        case .sourcePartial(let text):
            logger.info("EN rozmówcy (wersja robocza): \(text)")
        case .sourceFinal(let text):
            logger.notice("EN rozmówcy (finalne): \(text)")
        case .translationPartial(let text):
            logger.info("PL rozmówcy (wersja robocza): \(text)")
        case .translationFinal(let text):
            logger.notice("PL rozmówcy (finalne): \(text)")
        }
        subtitles.applyIncoming(event)
    }
}
