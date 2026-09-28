import AVFoundation
import Testing
@testable import MBTranslator

@Suite("PCM16MonoConverter")
struct PCM16MonoConverterTests {
    private func makeBuffer(sampleRate: Double, frames: Int, interleaved: Bool, left: Float, right: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: interleaved)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        if interleaved {
            let data = buffer.floatChannelData![0]
            for frame in 0..<frames {
                data[frame * 2] = left
                data[frame * 2 + 1] = right
            }
        } else {
            for frame in 0..<frames {
                buffer.floatChannelData![0][frame] = left
                buffer.floatChannelData![1][frame] = right
            }
        }
        return buffer
    }

    @Test("monoSamples averages channels — non-interleaved layout")
    func monoNonInterleaved() {
        let buffer = makeBuffer(sampleRate: 48000, frames: 4, interleaved: false, left: 1.0, right: 0.0)
        let mono = PCM16MonoConverter.monoSamples(from: buffer.audioBufferList, channels: 2, interleaved: false)
        #expect(mono == [0.5, 0.5, 0.5, 0.5])
    }

    @Test("monoSamples averages channels — interleaved layout")
    func monoInterleaved() {
        let buffer = makeBuffer(sampleRate: 48000, frames: 4, interleaved: true, left: 0.25, right: 0.75)
        let mono = PCM16MonoConverter.monoSamples(from: buffer.audioBufferList, channels: 2, interleaved: true)
        #expect(mono == [0.5, 0.5, 0.5, 0.5])
    }

    @Test("rejects non-Float32 source formats")
    func rejectsNonFloat() {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0
        )
        #expect(PCM16MonoConverter(sourceFormat: asbd) == nil)
        asbd.mFormatFlags = kAudioFormatFlagIsFloat
        asbd.mBitsPerChannel = 32
        #expect(PCM16MonoConverter(sourceFormat: asbd) != nil)
    }

    @Test("48 kHz stereo in → ~100 ms 16 kHz mono Int16 chunks out")
    func producesHundredMillisecondChunks() throws {
        let buffer = makeBuffer(sampleRate: 48000, frames: 480, interleaved: false, left: 0.5, right: 0.5)
        let converter = try #require(PCM16MonoConverter(sourceFormat: buffer.format.streamDescription.pointee))

        // 1 s of audio delivered as ten 10 ms IO-proc-sized buffers.
        var chunks: [Data] = []
        for _ in 0..<100 {
            chunks += converter.process(buffer.audioBufferList)
        }

        // Resampler latency may hold back a little at the tail, so allow ±1.
        #expect((9...10).contains(chunks.count))
        #expect(chunks.allSatisfy { $0.count == PCM16MonoConverter.chunkByteCount })

        // A constant 0.5 signal must come out as ~0.5 * Int16.max.
        let middle = chunks[chunks.count / 2]
        let sample = middle.withUnsafeBytes { $0.load(fromByteOffset: 1000, as: Int16.self) }
        #expect(abs(Int(sample) - Int(Float(Int16.max) * 0.5)) < 400)
    }
}
