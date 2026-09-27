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

/// Wires microphone capture → `SpeechTranslationService` together and, for
/// M2a, just logs the results — there is no UI for live subtitles yet
/// (that's M2b). Driven by the existing Start/Stop control in
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
    private let logger = Logger(subsystem: AppLogging.subsystem, category: "TranslationPipeline")

    var onStatusChange: ((TranslationStatus) -> Void)?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        microphoneCapture.stop()
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
                log(event)
            }
        } catch is CancellationError {
            // Normal stop.
        } catch {
            logger.error("Pipeline stopped with error: \(error.localizedDescription, privacy: .public)")
            onStatusChange?(.error(error.localizedDescription))
        }

        microphoneCapture.stop()
        task = nil
    }

    private func log(_ event: SpeechTranslationEvent) {
        switch event {
        case .sourcePartial(let text):
            logger.info("PL (wersja robocza): \(text)")
        case .sourceFinal(let text):
            logger.notice("PL (finalne): \(text)")
        case .translationPartial(let text):
            logger.info("EN (wersja robocza): \(text)")
        case .translationFinal(let text):
            logger.notice("EN (finalne): \(text)")
        }
    }
}
