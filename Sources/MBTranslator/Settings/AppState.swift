import Foundation
import Observation

enum TranslationStatus: Equatable {
    case idle
    case translating
    case error(String)

    var systemImage: String {
        switch self {
        case .idle: "waveform.circle"
        case .translating: "waveform.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var label: String {
        switch self {
        case .idle: String(localized: "Gotowe")
        case .translating: String(localized: "Tłumaczę")
        case .error: String(localized: "Błąd")
        }
    }
}

enum TranslationMode: String, CaseIterable, Identifiable {
    case translateMe
    case speakDirectly
    case muted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .translateMe: String(localized: "Tłumacz mnie")
        case .speakDirectly: String(localized: "Mów bezpośrednio")
        case .muted: String(localized: "Wycisz")
        }
    }
}

@Observable
final class AppState {
    var status: TranslationStatus = .idle
    var mode: TranslationMode = .translateMe
    var isRunning: Bool = false
    var latencyMilliseconds: Int?
}
