import AVFoundation
import os

enum MicrophoneCaptureError: Error, LocalizedError {
    case unsupportedTargetFormat
    case converterCreationFailed
    case engineStartFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedTargetFormat:
            String(localized: "Nieobsługiwany format audio docelowego (PCM16 16 kHz mono)")
        case .converterCreationFailed:
            String(localized: "Nie udało się utworzyć konwertera audio z mikrofonu")
        case .engineStartFailed:
            String(localized: "Nie udało się uruchomić przechwytywania z mikrofonu")
        }
    }
}

/// Captures the default microphone and yields PCM16 mono 16 kHz chunks
/// (~100 ms each), the format DeepL's/Azure's real-time speech APIs expect
/// (verified against DeepL's reference CLI — see docs/DECISIONS.md).
/// Not actor-isolated: driven synchronously from `TranslationPipelineController`
/// (`@MainActor`); the Core Audio tap callback only touches locally captured
/// values, never `self`, so it's safe regardless of caller's isolation.
final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<Data>.Continuation?
    private let logger = Logger(subsystem: AppLogging.subsystem, category: "MicrophoneCapture")

    func start() throws -> AsyncStream<Data> {
        stop()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw MicrophoneCaptureError.unsupportedTargetFormat
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw MicrophoneCaptureError.converterCreationFailed
        }

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation

        let tapBufferSize = AVAudioFrameCount(max(inputFormat.sampleRate * 0.1, 1600))
        let logger = self.logger

        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { buffer, _ in
            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let outputFrameCapacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 1)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
                return
            }

            var bufferConsumed = false
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                if bufferConsumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                bufferConsumed = true
                inputStatus.pointee = .haveData
                return buffer
            }

            guard status != .error else {
                if let conversionError {
                    logger.error("Audio conversion failed: \(conversionError.localizedDescription, privacy: .public)")
                }
                return
            }
            guard let channelData = outputBuffer.int16ChannelData, outputBuffer.frameLength > 0 else {
                return
            }

            let data = Data(bytes: channelData[0], count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size)
            continuation.yield(data)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            self.continuation = nil
            logger.error("Failed to start audio engine: \(error.localizedDescription, privacy: .public)")
            throw MicrophoneCaptureError.engineStartFailed
        }

        return stream
    }

    func stop() {
        guard engine.isRunning || continuation != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}
