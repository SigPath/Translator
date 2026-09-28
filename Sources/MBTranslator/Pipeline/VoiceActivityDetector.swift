import Foundation

/// Minimal RMS-based silence check on interleaved 16-bit PCM samples.
enum VoiceActivityDetector {
    /// Fallback/minimum threshold, used when `VoiceActivityGate` has no
    /// calibration data yet (or is constructed with `presetThreshold:` to
    /// skip calibration). Lowered from an initial guess of `500` after a
    /// real Mac test (see docs/DECISIONS.md, "Follow-up: kalibracja VAD")
    /// showed real background noise at ~9–25 and real speech at ~70–243 on
    /// this hardware — `500` silently discarded all speech. `50` sits
    /// between them with margin, and also serves as the floor
    /// `VoiceActivityGate`'s auto-calibration clamps to, so a near-silent
    /// room never yields an unrealistically low (over-sensitive) threshold.
    static let defaultSilenceThreshold: Double = 50

    static func rms(_ data: Data) -> Double {
        guard !data.isEmpty else { return 0 }

        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }

        let sumOfSquares: Double = data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            return samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        }
        return (sumOfSquares / Double(sampleCount)).squareRoot()
    }

    static func isSilence(_ data: Data, threshold: Double = defaultSilenceThreshold) -> Bool {
        rms(data) < threshold
    }
}

/// Gates whether an audio chunk should actually be sent to the translation
/// service: pauses sending during sustained silence (> `silenceThresholdMs`)
/// without ever closing the underlying session, per the DeepL/Azure billing
/// decision in docs/DECISIONS.md ("nie otwieramy nowej sesji na wypowiedź").
///
/// RMS (not peak) is used deliberately: it reflects sustained energy over
/// the ~100ms chunk, so a single transient click/pop doesn't register as
/// "voice" the way a peak-based measure would, and quiet background noise
/// with occasional peaks doesn't false-trigger either — the standard choice
/// for this kind of gating.
///
/// The threshold is **not** a fixed constant: absolute RMS level depends on
/// microphone gain/distance/room, which varies per device — a hardcoded
/// number (previously `500`, verified on real hardware to be roughly 2–7x
/// too high, see docs/DECISIONS.md) silently breaks on different hardware.
/// Instead the gate self-calibrates: it measures the background noise floor
/// over the first `calibrationDurationMs` of audio (letting all of that
/// audio through un-gated, so nothing is lost if speech starts immediately)
/// and sets the threshold to `noiseFloor * noiseMultiplier`, clamped to
/// never go below `minimumThreshold`.
struct VoiceActivityGate {
    private let silenceThresholdMs: Double
    private let chunkDurationMs: Double
    private var silentDurationMs: Double = 0

    private let calibrationChunkCount: Int
    private let noiseMultiplier: Double
    private let minimumThreshold: Double
    private var calibrationSamples: [Double] = []
    private var calibratedThreshold: Double?

    /// The threshold currently in effect, or `nil` while still calibrating
    /// (no threshold has been decided yet — every chunk is let through).
    var currentThreshold: Double? { calibratedThreshold }

    init(
        chunkDurationMs: Double,
        silenceThresholdMs: Double = 300,
        calibrationDurationMs: Double = 800,
        noiseMultiplier: Double = 3.0,
        minimumThreshold: Double = VoiceActivityDetector.defaultSilenceThreshold,
        presetThreshold: Double? = nil
    ) {
        self.chunkDurationMs = chunkDurationMs
        self.silenceThresholdMs = silenceThresholdMs
        self.calibrationChunkCount = max(1, Int((calibrationDurationMs / chunkDurationMs).rounded()))
        self.noiseMultiplier = noiseMultiplier
        self.minimumThreshold = minimumThreshold
        self.calibratedThreshold = presetThreshold
    }

    mutating func shouldSend(_ chunk: Data) -> Bool {
        let amplitude = VoiceActivityDetector.rms(chunk)

        guard let threshold = calibratedThreshold else {
            calibrationSamples.append(amplitude)
            guard calibrationSamples.count >= calibrationChunkCount else {
                // Still measuring the noise floor — let audio through rather
                // than risk dropping the start of real speech.
                silentDurationMs = 0
                return true
            }
            let noiseFloor = calibrationSamples.reduce(0, +) / Double(calibrationSamples.count)
            let threshold = max(minimumThreshold, noiseFloor * noiseMultiplier)
            calibratedThreshold = threshold
            print("[VoiceActivityGate] calibrated: noiseFloor=\(noiseFloor), threshold=\(threshold) (from \(calibrationSamples.count) chunks, ~\(Double(calibrationSamples.count) * chunkDurationMs)ms)") // TEMP (M2a debug)
            silentDurationMs = 0
            return true
        }

        guard amplitude < threshold else {
            silentDurationMs = 0
            return true
        }
        silentDurationMs += chunkDurationMs
        return silentDurationMs < silenceThresholdMs
    }
}
