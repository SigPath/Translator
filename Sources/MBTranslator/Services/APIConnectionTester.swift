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

    func testAzureSpeech(apiKey: String, region: String) async -> ConnectionTestResult {
        let trimmedRegion = region.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRegion.isEmpty,
              let url = URL(string: "https://\(trimmedRegion).api.cognitive.microsoft.com/sts/v1.0/issueToken")
        else {
            return .failure(String(localized: "Nieprawidłowy region"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
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
        } catch let urlError as URLError where urlError.code == .cannotFindHost || urlError.code == .cannotConnectToHost {
            return .failure(String(localized: "Nieprawidłowy region lub brak połączenia z siecią"))
        } catch {
            logger.error("Connection test failed: \(error.localizedDescription, privacy: .public)")
            return .failure(String(localized: "Brak połączenia z siecią"))
        }
    }
}
