import Foundation

/// Minimal RMS-based silence check on interleaved 16-bit PCM samples.
enum VoiceActivityDetector {
    static func isSilence(_ data: Data, threshold: Double = 500) -> Bool {
        guard !data.isEmpty else { return true }

        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return true }

        let sumOfSquares: Double = data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            return samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        }
        let rms = (sumOfSquares / Double(sampleCount)).squareRoot()
        return rms < threshold
    }
}

/// Gates whether an audio chunk should actually be sent to the translation
/// service: pauses sending during sustained silence (> `silenceThresholdMs`)
/// without ever closing the underlying session, per the DeepL/Azure billing
/// decision in docs/DECISIONS.md ("nie otwieramy nowej sesji na wypowiedź").
struct VoiceActivityGate {
    private let silenceThresholdMs: Double
    private let chunkDurationMs: Double
    private var silentDurationMs: Double = 0

    init(chunkDurationMs: Double, silenceThresholdMs: Double = 300) {
        self.chunkDurationMs = chunkDurationMs
        self.silenceThresholdMs = silenceThresholdMs
    }

    mutating func shouldSend(_ chunk: Data) -> Bool {
        guard VoiceActivityDetector.isSilence(chunk) else {
            silentDurationMs = 0
            return true
        }
        silentDurationMs += chunkDurationMs
        return silentDurationMs < silenceThresholdMs
    }
}
