import Foundation

/// Result of speech translation, as segments arrive. Only `sourceFinal`/
/// `translationFinal` represent settled text; `*Partial` are live, in-progress
/// guesses that can still change and must never be fed to TTS (per brief:
/// "tylko finalne segmenty idą do TTS").
enum SpeechTranslationEvent: Sendable, Equatable {
    case sourcePartial(String)
    case sourceFinal(String)
    case translationPartial(String)
    case translationFinal(String)
}

enum SpeechTranslationError: Error, LocalizedError, Equatable {
    case invalidRegion
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRegion:
            String(localized: "Nieprawidłowy region Azure Speech")
        case .connectionFailed(let reason):
            "\(String(localized: "Nie udało się połączyć z Azure Speech")): \(reason)"
        }
    }
}

/// Abstraction over a real-time speech-to-text + translation provider, so the
/// backend (currently Azure AI Speech) can be swapped without touching the
/// rest of the pipeline — validated in practice by the earlier DeepL→Azure
/// switch, done entirely at the Settings/Keychain layer before this protocol
/// existed.
protocol SpeechTranslationService: Sendable {
    /// Streams translation events for as long as `audioChunks` keeps
    /// producing PCM16 mono 16 kHz frames. Ends when `audioChunks` finishes;
    /// throws only after exhausting internal reconnect/backoff attempts.
    func recognize(
        audioChunks: AsyncStream<Data>,
        sourceLanguage: String,
        targetLanguage: String
    ) -> AsyncThrowingStream<SpeechTranslationEvent, Error>
}
