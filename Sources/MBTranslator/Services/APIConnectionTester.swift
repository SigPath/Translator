import Foundation
import os

enum ConnectionTestResult: Equatable {
    case success
    case failure(String)
}

/// Minimal reachability check for provider API keys, used by the Settings
/// "Testuj połączenie" button. Deliberately independent of the translation
/// pipeline (which doesn't exist yet) — it only verifies the key is accepted.
struct APIConnectionTester {
    private let logger = Logger(subsystem: AppLogging.subsystem, category: "APIConnectionTester")

    func testDeepL(apiKey: String) async -> ConnectionTestResult {
        var request = URLRequest(url: URL(string: "https://api.deepl.com/v2/usage")!)
        request.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        return await performCheck(request)
    }

    func testElevenLabs(apiKey: String) async -> ConnectionTestResult {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/user")!)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return await performCheck(request)
    }

    private func performCheck(_ request: URLRequest) async -> ConnectionTestResult {
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(String(localized: "Nieprawidłowa odpowiedź serwera"))
            }
            switch httpResponse.statusCode {
            case 200..<300:
                return .success
            case 401, 403:
                return .failure(String(localized: "Nieprawidłowy klucz API"))
            case 429:
                return .failure(String(localized: "Przekroczono limit zapytań"))
            default:
                return .failure("\(String(localized: "Błąd serwera")) (\(httpResponse.statusCode))")
            }
        } catch {
            logger.error("Connection test failed: \(error.localizedDescription, privacy: .public)")
            return .failure(String(localized: "Brak połączenia z siecią"))
        }
    }
}
