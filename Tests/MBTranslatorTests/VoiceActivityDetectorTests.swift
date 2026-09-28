import Foundation
import Testing
@testable import MBTranslator

@Suite("VoiceActivityDetector / VoiceActivityGate")
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

    @Test("Gate keeps sending through brief silence, then stops after the threshold")
    func gateStopsSendingAfterSustainedSilence() {
        // presetThreshold skips auto-calibration so this tests the pure
        // grace-period gating logic in isolation, independent of it.
        var gate = VoiceActivityGate(chunkDurationMs: 100, silenceThresholdMs: 300, presetThreshold: VoiceActivityDetector.defaultSilenceThreshold)
        let silentChunk = pcm16Data(Array(repeating: 0, count: 1600))

        // 100ms, 200ms of accumulated silence: still under the 300ms threshold.
        #expect(gate.shouldSend(silentChunk))
        #expect(gate.shouldSend(silentChunk))
        // 300ms accumulated: now at/over threshold, stop sending.
        #expect(!gate.shouldSend(silentChunk))
    }

    @Test("Gate resumes sending immediately once speech returns")
    func gateResumesOnSpeech() {
        var gate = VoiceActivityGate(chunkDurationMs: 100, silenceThresholdMs: 300, presetThreshold: VoiceActivityDetector.defaultSilenceThreshold)
        let silentChunk = pcm16Data(Array(repeating: 0, count: 1600))
        let loudChunk = pcm16Data(Array(repeating: 20000, count: 1600))

        _ = gate.shouldSend(silentChunk)
        _ = gate.shouldSend(silentChunk)
        _ = gate.shouldSend(silentChunk) // now silenced

        #expect(gate.shouldSend(loudChunk))
    }

    @Test("Gate auto-calibrates its threshold to a multiple of the measured noise floor")
    func gateAutoCalibratesToNoiseFloor() {
        var gate = VoiceActivityGate(chunkDurationMs: 100, silenceThresholdMs: 300, calibrationDurationMs: 300, noiseMultiplier: 3.0, minimumThreshold: 10)
        let noiseChunk = pcm16Data(Array(repeating: 20, count: 1600)) // constant value -> RMS == 20 exactly

        #expect(gate.currentThreshold == nil) // not calibrated yet
        _ = gate.shouldSend(noiseChunk)
        _ = gate.shouldSend(noiseChunk)
        _ = gate.shouldSend(noiseChunk) // 3 * 100ms == calibrationDurationMs: calibration completes here

        #expect(gate.currentThreshold == 60) // 20 * 3.0
    }

    @Test("Calibrated threshold correctly recognizes moderate speech a fixed high threshold would have missed")
    func calibratedThresholdRecognizesModerateSpeech() {
        // Mirrors the real bug report: background noise ~9-25, real speech
        // ~70-243, and the old hardcoded threshold of 500 silently discarded
        // all of it.
        var gate = VoiceActivityGate(chunkDurationMs: 100, silenceThresholdMs: 300, calibrationDurationMs: 300, noiseMultiplier: 3.0, minimumThreshold: 10)
        let noiseChunk = pcm16Data(Array(repeating: 20, count: 1600))
        let moderateSpeechChunk = pcm16Data(Array(repeating: 90, count: 1600))

        _ = gate.shouldSend(noiseChunk)
        _ = gate.shouldSend(noiseChunk)
        _ = gate.shouldSend(noiseChunk) // calibrates to threshold == 60

        #expect(gate.shouldSend(moderateSpeechChunk)) // 90 > 60 -> recognized as voice
    }

    @Test("Calibrated threshold never drops below the configured minimum in a near-silent room")
    func gateClampsThresholdToMinimum() {
        var gate = VoiceActivityGate(chunkDurationMs: 100, silenceThresholdMs: 300, calibrationDurationMs: 200, noiseMultiplier: 3.0, minimumThreshold: 50)
        let silentChunk = pcm16Data(Array(repeating: 0, count: 1600)) // RMS == 0

        _ = gate.shouldSend(silentChunk)
        _ = gate.shouldSend(silentChunk) // calibration completes: noiseFloor * 3.0 == 0, clamped to minimumThreshold

        #expect(gate.currentThreshold == 50)
    }
}
