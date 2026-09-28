import Foundation

/// Persists the ElevenLabs cloned-voice `voice_id` — not a secret (it's not
/// usable without the separately-stored API key), so plain `UserDefaults`
/// rather than Keychain, same reasoning as `AudioSettingsStore`.
///
/// The voice itself is recorded/cloned directly in the ElevenLabs web app
/// for now; Marcin pastes the resulting `voice_id` here. An in-app "record a
/// voice sample" wizard is separately planned for M5 — this field is the
/// simple placeholder until then.
/// `@unchecked Sendable`: safe because the only stored state is an
/// immutable `let defaults: UserDefaults`, and UserDefaults itself is
/// thread-safe.
final class ElevenLabsSettingsStore: @unchecked Sendable {
    static let shared = ElevenLabsSettingsStore()

    private static let voiceIDKey = "pl.mbgroup.translator.elevenlabs.voiceID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var voiceID: String? {
        get { defaults.string(forKey: Self.voiceIDKey) }
        set { defaults.set(newValue, forKey: Self.voiceIDKey) }
    }
}
