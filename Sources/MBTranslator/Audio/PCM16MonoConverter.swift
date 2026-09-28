import AVFoundation
import CoreAudio
import os

/// Turns raw Core Audio buffers (as delivered to an IO proc — Float32,
/// any sample rate, any channel count, interleaved or not) into the
/// PCM16 mono 16 kHz, ~100 ms chunks Azure's real-time speech API expects
/// (same target format as `MicrophoneCapture`, see docs/DECISIONS.md).
///
/// Used by `ProcessTapCapture` (M4). `MicrophoneCapture` keeps its own
/// hard-won, hardware-verified conversion code untouched. Not thread-safe:
/// driven from a single serial queue (the process tap's IO queue).
final class PCM16MonoConverter: @unchecked Sendable {
    /// 100 ms of 16 kHz mono Int16 — same chunk size as the microphone
    /// path, which `AzureSpeechTranslationService`'s diagnostics assume.
    static let chunkByteCount = 3200

    private let sourceChannels: Int
    private let isInterleaved: Bool
    private let monoFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var pending = Data()

    /// Returns `nil` for anything but Float32 linear PCM — that's what a
    /// Core Audio process tap delivers; anything else is refused loudly by
    /// the caller rather than silently mis-decoded.
    init?(sourceFormat asbd: AudioStreamBasicDescription) {
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32,
              asbd.mChannelsPerFrame > 0,
              asbd.mSampleRate > 0,
              let monoFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: asbd.mSampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let targetFormat = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: 16000,
                  channels: 1,
                  interleaved: true
              ),
              let converter = AVAudioConverter(from: monoFormat, to: targetFormat)
        else {
            return nil
        }
        self.sourceChannels = Int(asbd.mChannelsPerFrame)
        self.isInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        self.monoFormat = monoFormat
        self.targetFormat = targetFormat
        self.converter = converter
    }

    /// Converts one IO-proc buffer and returns every *complete* 100 ms
    /// chunk now available (usually zero or one — IO procs deliver far
    /// smaller buffers than 100 ms); the remainder is kept for next call.
    func process(_ list: UnsafePointer<AudioBufferList>) -> [Data] {
        let samples = Self.monoSamples(from: list, channels: sourceChannels, interleaved: isInterleaved)
        guard !samples.isEmpty,
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let monoChannel = monoBuffer.floatChannelData?[0]
        else {
            return []
        }
        samples.withUnsafeBufferPointer { monoChannel.update(from: $0.baseAddress!, count: samples.count) }
        monoBuffer.frameLength = AVAudioFrameCount(samples.count)

        let ratio = targetFormat.sampleRate / monoFormat.sampleRate
        let outputCapacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up) + 1)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return []
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return monoBuffer
        }
        guard status != .error, conversionError == nil,
              let channelData = outputBuffer.int16ChannelData, outputBuffer.frameLength > 0
        else {
            return []
        }
        pending.append(Data(bytes: channelData[0], count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size))

        var chunks: [Data] = []
        while pending.count >= Self.chunkByteCount {
            chunks.append(Data(pending.prefix(Self.chunkByteCount)))
            pending.removeFirst(Self.chunkByteCount)
        }
        return chunks
    }

    /// Averages all channels into one. Handles both layouts an IO proc can
    /// deliver: one interleaved buffer, or one buffer per channel.
    static func monoSamples(from list: UnsafePointer<AudioBufferList>, channels: Int, interleaved: Bool) -> [Float] {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let floatSize = MemoryLayout<Float>.size

        if interleaved {
            guard let first = buffers.first, let raw = first.mData else { return [] }
            let frames = Int(first.mDataByteSize) / (floatSize * channels)
            let samples = raw.assumingMemoryBound(to: Float.self)
            return (0..<frames).map { frame in
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += samples[frame * channels + channel]
                }
                return sum / Float(channels)
            }
        }

        let planes = buffers.compactMap { buffer -> (UnsafePointer<Float>, Int)? in
            guard let raw = buffer.mData else { return nil }
            return (UnsafePointer(raw.assumingMemoryBound(to: Float.self)), Int(buffer.mDataByteSize) / floatSize)
        }
        guard let frames = planes.map(\.1).min(), frames > 0 else { return [] }
        return (0..<frames).map { frame in
            var sum: Float = 0
            for (plane, _) in planes {
                sum += plane[frame]
            }
            return sum / Float(planes.count)
        }
    }
}
