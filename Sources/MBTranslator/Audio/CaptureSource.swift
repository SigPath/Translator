import Foundation

/// Which application's audio the M4 "tor B" process tap listens to.
///
/// `.teams` is the product's real source (the remote party's voice).
/// `.browser` exists as a **testing aid**: it lets M4 be verified with
/// any English YouTube video instead of needing a live Teams call — see
/// docs/DECISIONS.md, "M4: źródło testowe — przeglądarka".
enum CaptureSource: String, CaseIterable, Identifiable, Sendable {
    case teams
    case browser

    var id: String { rawValue }

    var label: String {
        switch self {
        case .teams: String(localized: "Microsoft Teams")
        case .browser: String(localized: "Przeglądarka (test, np. YouTube)")
        }
    }

    /// Human-readable name for the "not found" error message.
    var notFoundHint: String {
        switch self {
        case .teams:
            String(localized: "Nie znaleziono Microsoft Teams — uruchom Teams (najlepiej w trakcie rozmowy) i spróbuj ponownie")
        case .browser:
            String(localized: "Nie znaleziono przeglądarki odtwarzającej dźwięk — włącz film (np. na YouTube) i spróbuj ponownie")
        }
    }

    /// Bundle-ID *prefixes*, lowercased. Prefix matching on purpose: apps
    /// render audio from helper processes whose bundle IDs extend the main
    /// one (`com.microsoft.teams2.modulehost`, `com.google.Chrome.helper…`),
    /// and tapping only the main process would hear nothing.
    var bundleIDPrefixes: [String] {
        switch self {
        case .teams:
            ["com.microsoft.teams"]
        case .browser:
            [
                "com.google.chrome",
                "com.apple.safari",
                // Safari plays page audio from WebKit's own GPU/WebContent
                // processes, not from the Safari app process.
                "com.apple.webkit",
                "company.thebrowser.browser", // Arc
                "com.microsoft.edgemac",
                "org.mozilla.firefox",
                "org.mozilla.plugincontainer",
                "com.brave.browser",
                "com.vivaldi.vivaldi",
                "com.operasoftware.opera",
            ]
        }
    }

    func matches(bundleID: String) -> Bool {
        let lowered = bundleID.lowercased()
        return bundleIDPrefixes.contains { lowered.hasPrefix($0) }
    }
}
