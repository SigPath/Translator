import Foundation

/// Persists non-secret audio preferences (device UIDs). Separate from
/// KeychainStore, which is reserved for API keys/secrets.
/// `@unchecked Sendable`: safe because the only stored state is an
/// immutable `let defaults: UserDefaults`, and UserDefaults itself is
/// thread-safe.
final class AudioSettingsStore: @unchecked Sendable {
    static let shared = AudioSettingsStore()

    private static let selectedOutputDeviceUIDKey = "pl.mbgroup.translator.audio.selectedOutputDeviceUID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedOutputDeviceUID: String? {
        get { defaults.string(forKey: Self.selectedOutputDeviceUIDKey) }
        set { defaults.set(newValue, forKey: Self.selectedOutputDeviceUIDKey) }
    }
}
