import Observation

/// Live text for the M2b floating subtitles panel, updated as
/// `SpeechTranslationEvent`s arrive from `TranslationPipelineController`.
///
/// Deliberately holds only the *current* line per category, not an
/// accumulating transcript — matches how live captions work elsewhere
/// (Teams/Zoom): each new result replaces the last, it doesn't append to
/// a growing log. `sourcePartial` gives the user immediate "yes, it's
/// hearing me" feedback while speaking; `translationPartial` is
/// intentionally *not* tracked here (only `translationFinal`) — partial
/// translations can reword significantly before settling, and flickering
/// through those mid-sentence would be more distracting than useful for a
/// glance-at overlay. `sourceFinal`/`translationFinal` are what actually
/// got recognized/translated once Azure's endpointer closed the phrase.
@Observable
@MainActor
final class SubtitlesState {
    var sourcePartial: String = ""
    var sourceFinal: String = ""
    var translationFinal: String = ""

    func apply(_ event: SpeechTranslationEvent) {
        switch event {
        case .sourcePartial(let text):
            sourcePartial = text
        case .sourceFinal(let text):
            sourceFinal = text
            // A final result settles the phrase; the live partial above it
            // is now stale (it was mid-sentence guessing toward this exact
            // text) and would just sit there duplicating `sourceFinal`.
            sourcePartial = ""
        case .translationPartial:
            break
        case .translationFinal(let text):
            translationFinal = text
        }
    }

    func reset() {
        sourcePartial = ""
        sourceFinal = ""
        translationFinal = ""
    }
}
