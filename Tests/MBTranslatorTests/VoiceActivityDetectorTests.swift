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
        var gate = VoiceActivityGate(chunkDurationMs: 100, silenceThresholdMs: 300)
        let silentChunk = pcm16Data(Array(repeating: 0, count: 1600))

        // 100ms, 200ms of accumulated silence: still under the 300ms threshold.
        #expect(gate.shouldSend(silentChunk))
        #expect(gate.shouldSend(silentChunk))
        // 300ms accumulated: now at/over threshold, stop sending.
        #expect(!gate.shouldSend(silentChunk))
    }

    @Test("Gate resumes sending immediately once speech returns")
    func gateResumesOnSpeech() {
        var gate = VoiceActivityGate(chunkDurationMs: 100, silenceThresholdMs: 300)
        let silentChunk = pcm16Data(Array(repeating: 0, count: 1600))
        let loudChunk = pcm16Data(Array(repeating: 20000, count: 1600))

        _ = gate.shouldSend(silentChunk)
        _ = gate.shouldSend(silentChunk)
        _ = gate.shouldSend(silentChunk) // now silenced

        #expect(gate.shouldSend(loudChunk))
    }
}
