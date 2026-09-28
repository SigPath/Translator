import Foundation
import os

/// Minimal RMS-based silence check on interleaved 16-bit PCM samples.
enum VoiceActivityDetector {
    /// Fallback/minimum threshold, used when `VoiceActivityTracker` has no
    /// calibration data yet (or is constructed with `presetThreshold:` to
    /// skip calibration). Lowered from an initial guess of `500` after a
    /// real Mac test (see docs/DECISIONS.md, "Follow-up: kalibracja VAD")
    /// showed real background noise at ~9–25 and real speech at ~70–243 on
    /// this hardware — `500` silently discarded all speech. `50` sits
    /// between them with margin, and also serves as the floor
    /// `VoiceActivityTracker`'s auto-calibration clamps to, so a
    /// near-silent room never yields an unrealistically low
    /// (over-sensitive) threshold.
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

/// Tracks whether the user is currently considered to be speaking, for
/// diagnostics and a future "listening/speaking" UI indicator (M2b) —
/// it does **not** gate which audio chunks get sent to Azure.
///
/// It used to: an earlier version paused sending audio chunks during
/// sustained silence, reusing an approach from an earlier DeepL-based
/// design (see docs/DECISIONS.md, "Billing DeepL a cisza w trwającej
/// sesji" — HISTORYCZNE). For Azure this was actively wrong and caused a
/// real bug: Azure's real-time endpoint performs its own server-side
/// VAD/end-of-utterance detection on the continuous audio stream it
/// receives, so a client that stops sending bytes during silence gives the
/// server nothing to detect "speech ended" from — no final `SpeechPhrase`
/// ever arrived, even after a deliberate silence pause, because our own
/// gate was discarding exactly the silence Azure's endpointer needed to
/// see (confirmed: docs/DECISIONS.md, "Follow-up: VAD nigdy nie widziało
/// ciszy po stronie Azure"). Audio is now always sent regardless of this
/// type's verdict; only the verdict itself (and its calibrated threshold)
/// is still useful, for logging and eventually for UI.
///
/// RMS (not peak) is used deliberately: it reflects sustained energy over
/// the ~100ms chunk, so a single transient click/pop doesn't register as
/// "voice" the way a peak-based measure would, and quiet background noise
/// with occasional peaks doesn't false-trigger either — the standard choice
/// for this kind of detection.
///
/// The threshold is **not** a fixed constant: absolute RMS level depends on
/// microphone gain/distance/room, which varies per device — a hardcoded
/// number (previously `500`, verified on real hardware to be roughly 2–7x
/// too high, see docs/DECISIONS.md) silently breaks on different hardware.
/// Instead the tracker self-calibrates: it measures the background noise
/// floor over the first `calibrationDurationMs` of audio and sets the
/// threshold to `noiseFloor * noiseMultiplier`, clamped to never go below
/// `minimumThreshold`.
struct VoiceActivityTracker {
    private let logger = Logger(subsystem: AppLogging.subsystem, category: "VoiceActivityTracker")
    private let silenceThresholdMs: Double
    private let chunkDurationMs: Double
    private var silentDurationMs: Double = 0

    private let calibrationChunkCount: Int
    private let noiseMultiplier: Double
    private let minimumThreshold: Double
    private var calibrationSamples: [Double] = []
    private var calibratedThreshold: Double?

    /// The threshold currently in effect, or `nil` while still calibrating
    /// (no threshold has been decided yet — every chunk is reported as
    /// "speech" until calibration completes).
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

    /// Reports whether `chunk` should currently be considered "speech" —
    /// with a grace period (`silenceThresholdMs`) after voice stops, so
    /// brief pauses mid-sentence don't immediately flip the verdict. Purely
    /// informational: the caller decides what to do with this, if anything.
    mutating func isSpeechDetected(_ chunk: Data) -> Bool {
        let amplitude = VoiceActivityDetector.rms(chunk)

        guard let threshold = calibratedThreshold else {
            calibrationSamples.append(amplitude)
            guard calibrationSamples.count >= calibrationChunkCount else {
                // Still measuring the noise floor.
                silentDurationMs = 0
                return true
            }
            let noiseFloor = calibrationSamples.reduce(0, +) / Double(calibrationSamples.count)
            let threshold = max(minimumThreshold, noiseFloor * noiseMultiplier)
            calibratedThreshold = threshold
            // `Logger.notice(_:)`'s message parameter is `@autoclosure
            // @escaping` (so the interpolation work can be skipped entirely
            // when the log level is disabled) — an escaping closure can't
            // implicitly capture `self` inside a `mutating func` (`self` is
            // effectively `inout` there), so every value the message needs
            // must be a local `let` first, not a `self.`-accessed property
            // read inline in the interpolation.
            let sampleCount = calibrationSamples.count
            let elapsedMs = Double(sampleCount) * chunkDurationMs
            logger.notice("Calibrated: noiseFloor=\(noiseFloor), threshold=\(threshold) (from \(sampleCount) chunks, ~\(elapsedMs)ms)")
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
