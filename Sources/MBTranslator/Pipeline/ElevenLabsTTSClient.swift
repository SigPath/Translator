import Foundation
import os

enum ElevenLabsTTSError: Error, LocalizedError {
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            String(localized: "Nieprawidłowa odpowiedź serwera ElevenLabs")
        case .requestFailed(let status):
            "\(String(localized: "Błąd ElevenLabs")) (\(status))"
        }
    }
}

/// Minimal client for ElevenLabs' Text-to-Speech "convert" endpoint
/// (`POST /v1/text-to-speech/{voice_id}`), verified against real API
/// documentation (endpoint shape, `xi-api-key` auth header — already used
/// and confirmed working for `GET /v1/user` in `APIConnectionTester` —
/// `model_id`/`voice_settings` request body, `output_format` query param).
///
/// Requests a fixed `mp3_44100_128` output rather than a raw PCM format:
/// PCM/WAV at 44.1kHz requires an ElevenLabs Pro-tier-or-above account,
/// while MP3 output is available on all tiers and `AVAudioFile` (used by
/// `DirectSpeechPlayer`) decodes it natively via Core Audio — no need to
/// parse or convert anything ourselves.
struct ElevenLabsTTSClient {
    private let logger = Logger(subsystem: AppLogging.subsystem, category: "ElevenLabsTTSClient")

    func synthesize(text: String, apiKey: String, voiceID: String) async throws -> Data {
        var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)")!
        components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
        guard let url = components.url else {
            throw ElevenLabsTTSError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": "eleven_multilingual_v2",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75,
            ],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ElevenLabsTTSError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            logger.error("ElevenLabs TTS request failed: HTTP \(httpResponse.statusCode, privacy: .public)")
            throw ElevenLabsTTSError.requestFailed(httpResponse.statusCode)
        }
        return data
    }
}
