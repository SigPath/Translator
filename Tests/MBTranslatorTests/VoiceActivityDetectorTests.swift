import Foundation
import Testing
@testable import MBTranslator

@Suite("VoiceActivityDetector / VoiceActivityTracker")
struct VoiceActivityDetectorTests {
    private func pcm16Data(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    @Test("Silence (all zero samples) is detected as silence")
    func silenceDetected() {
        let silentChunk = pcm16Data(Array(repeating: 0, count: 1600))
        #expect(VoiceActivityDetector.isSilence(silentChunk))
    }

    @Test("Loud samples are not silence")
    func loudSamplesNotSilence() {
        let loudChunk = pcm16Data(Array(repeating: 20000, count: 1600))
        #expect(!VoiceActivityDetector.isSilence(loudChunk))
    }

    @Test("Empty data counts as silence")
    func emptyDataIsSilence() {
        #expect(VoiceActivityDetector.isSilence(Data()))
    }

    @Test("Tracker keeps reporting speech through brief silence, then flips after the threshold")
    func trackerStopsReportingSpeechAfterSustainedSilence() {
        // presetThreshold skips auto-calibration so this tests the pure
        // grace-period detection logic in isolation, independent of it.
        var tracker = VoiceActivityTracker(chunkDurationMs: 100, silenceThresholdMs: 300, presetThreshold: VoiceActivityDetector.defaultSilenceThreshold)
        let silentChunk = pcm16Data(Array(repeating: 0, count: 1600))

        // 100ms, 200ms of accumulated silence: still under the 300ms threshold.
        let detected1 = tracker.isSpeechDetected(silentChunk)
        #expect(detected1)
        let detected2 = tracker.isSpeechDetected(silentChunk)
        #expect(detected2)
        // 300ms accumulated: now at/over threshold, reports silence.
        let detected3 = tracker.isSpeechDetected(silentChunk)
        #expect(!detected3)
    }

    @Test("Tracker reports speech again immediately once speech returns")
    func trackerResumesOnSpeech() {
        var tracker = VoiceActivityTracker(chunkDurationMs: 100, silenceThresholdMs: 300, presetThreshold: VoiceActivityDetector.defaultSilenceThreshold)
        let silentChunk = pcm16Data(Array(repeating: 0, count: 1600))
        let loudChunk = pcm16Data(Array(repeating: 20000, count: 1600))

        _ = tracker.isSpeechDetected(silentChunk)
        _ = tracker.isSpeechDetected(silentChunk)
        _ = tracker.isSpeechDetected(silentChunk) // now silenced

        let detected4 = tracker.isSpeechDetected(loudChunk)
        #expect(detected4)
    }

    @Test("Tracker auto-calibrates its threshold to a multiple of the measured noise floor")
    func trackerAutoCalibratesToNoiseFloor() {
        var tracker = VoiceActivityTracker(chunkDurationMs: 100, silenceThresholdMs: 300, calibrationDurationMs: 300, noiseMultiplier: 3.0, minimumThreshold: 10)
        let noiseChunk = pcm16Data(Array(repeating: 20, count: 1600)) // constant value -> RMS == 20 exactly

        #expect(tracker.currentThreshold == nil) // not calibrated yet
        _ = tracker.isSpeechDetected(noiseChunk)
        _ = tracker.isSpeechDetected(noiseChunk)
        _ = tracker.isSpeechDetected(noiseChunk) // 3 * 100ms == calibrationDurationMs: calibration completes here

        #expect(tracker.currentThreshold == 60) // 20 * 3.0
    }

    @Test("Calibrated threshold correctly recognizes moderate speech a fixed high threshold would have missed")
    func calibratedThresholdRecognizesModerateSpeech() {
        // Mirrors the real bug report: background noise ~9-25, real speech
        // ~70-243, and the old hardcoded threshold of 500 silently discarded
        // all of it.
        var tracker = VoiceActivityTracker(chunkDurationMs: 100, silenceThresholdMs: 300, calibrationDurationMs: 300, noiseMultiplier: 3.0, minimumThreshold: 10)
        let noiseChunk = pcm16Data(Array(repeating: 20, count: 1600))
        let moderateSpeechChunk = pcm16Data(Array(repeating: 90, count: 1600))

        _ = tracker.isSpeechDetected(noiseChunk)
        _ = tracker.isSpeechDetected(noiseChunk)
        _ = tracker.isSpeechDetected(noiseChunk) // calibrates to threshold == 60

        let detected5 = tracker.isSpeechDetected(moderateSpeechChunk)
        #expect(detected5) // 90 > 60 -> recognized as voice
    }

    @Test("Calibrated threshold never drops below the configured minimum in a near-silent room")
    func trackerClampsThresholdToMinimum() {
        var tracker = VoiceActivityTracker(chunkDurationMs: 100, silenceThresholdMs: 300, calibrationDurationMs: 200, noiseMultiplier: 3.0, minimumThreshold: 50)
        let silentChunk = pcm16Data(Array(repeating: 0, count: 1600)) // RMS == 0

        _ = tracker.isSpeechDetected(silentChunk)
        _ = tracker.isSpeechDetected(silentChunk) // calibration completes: noiseFloor * 3.0 == 0, clamped to minimumThreshold

        #expect(tracker.currentThreshold == 50)
    }
}
