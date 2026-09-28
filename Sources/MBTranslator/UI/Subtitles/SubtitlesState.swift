import Observation

/// One side of the subtitles panel: the current source line (live partial,
/// then final) and its final translation.
///
/// Deliberately holds only the *current* line per category, not an
/// accumulating transcript — matches how live captions work elsewhere
/// (Teams/Zoom): each new result replaces the last, it doesn't append to
/// a growing log. `sourcePartial` gives immediate "yes, it's hearing" feedback
/// while speaking; `translationPartial` is intentionally *not* tracked (only
/// `translationFinal`) — partial translations can reword significantly
/// before settling, and flickering through those mid-sentence would be more
/// distracting than useful for a glance-at overlay.
struct LiveCaption: Equatable {
    var sourcePartial: String = ""
    var sourceFinal: String = ""
    var translationFinal: String = ""

    mutating func apply(_ event: SpeechTranslationEvent) {
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
}

/// Live text for the floating subtitles panel, which (M4) has two
/// independent sides:
/// - **outgoing** (left): the user's own speech, PL → EN, fed by
///   `TranslationPipelineController` (microphone);
/// - **incoming** (right): the remote party in Teams, EN → PL, fed by
///   `IncomingTranslationController` (process tap).
///
/// The two tracks start/stop independently, so each side has its own
/// "active" flag (drives the placeholder text) and its own reset.
@Observable
@MainActor
final class SubtitlesState {
    private(set) var outgoing = LiveCaption()
    private(set) var incoming = LiveCaption()
    var isOutgoingActive = false
    var isIncomingActive = false

    // Read-only views of the outgoing side, kept under their original names
    // (the M2b API) so existing callers/tests are unaffected by the split.
    var sourcePartial: String { outgoing.sourcePartial }
    var sourceFinal: String { outgoing.sourceFinal }
    var translationFinal: String { outgoing.translationFinal }

    func apply(_ event: SpeechTranslationEvent) {
        outgoing.apply(event)
    }

    func applyIncoming(_ event: SpeechTranslationEvent) {
        incoming.apply(event)
    }

    func resetOutgoing() {
        outgoing = LiveCaption()
    }

    func resetIncoming() {
        incoming = LiveCaption()
    }

    func reset() {
        resetOutgoing()
        resetIncoming()
    }
}
