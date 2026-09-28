import AVFoundation
import os

enum MicrophoneCaptureError: Error, LocalizedError {
    case unsupportedTargetFormat
    case engineStartFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedTargetFormat:
            String(localized: "Nieobsługiwany format audio docelowego (PCM16 16 kHz mono)")
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
/// values (never `self`), so it's safe regardless of caller's isolation.
///
/// The tap is installed with `format: nil` rather than a format queried
/// separately via `inputNode.outputFormat(forBus:)` beforehand. Passing a
/// separately-queried format is a documented, real-world cause of
/// `kAudioUnitErr_InvalidElement` (-10877) on macOS: that query can be
/// stale/mismatched by the time the tap is actually installed, and the
/// resulting failure surfaces as an Objective-C exception inside
/// `installTap` itself — which Swift's `do/catch` cannot catch — so it
/// silently breaks the tap without ever throwing a Swift `Error` we could
/// log. `format: nil` instead makes AVFAudio use whatever format the node
/// actually negotiates at install time; the converter is then built lazily
/// from each buffer's own `.format`, which is always accurate by
/// construction. See docs/DECISIONS.md for sources.
final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<Data>.Continuation?
    private let logger = Logger(subsystem: AppLogging.subsystem, category: "MicrophoneCapture")
    private var configChangeObserver: NSObjectProtocol?

    func start() throws -> AsyncStream<Data> {
        stop()

        let inputNode = engine.inputNode

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw MicrophoneCaptureError.unsupportedTargetFormat
        }

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation

        let logger = self.logger
        // Closure-local state, owned solely by the (serial) tap callback —
        // never touched from `start()`/`stop()` again after this point.
        var converter: AVAudioConverter?
        var converterSourceFormat: AVAudioFormat?
        var didLogFirstBuffer = false

        inputNode.installTap(onBus: 0, bufferSize: 1600, format: nil) { buffer, _ in
            if !didLogFirstBuffer {
                didLogFirstBuffer = true
                logger.notice("First microphone buffer received")
            }

            // Manual downmix to mono, done explicitly here rather than via
            // `AVAudioConverter.downmix` (verified unreliable for a tap
            // buffer with no explicit `AVAudioChannelLayout` — see
            // docs/DECISIONS.md).
            guard let monoBuffer = Self.monoDownmix(of: buffer, logger: logger) else {
                logger.error("Could not downmix microphone buffer to mono")
                return
            }
            let monoSourceFormat = monoBuffer.format

            if converter == nil || converterSourceFormat != monoSourceFormat {
                converter = AVAudioConverter(from: monoSourceFormat, to: targetFormat)
                converterSourceFormat = monoSourceFormat
                if converter == nil {
                    logger.error("Could not create converter for mic format: \(monoSourceFormat.description, privacy: .public)")
                }
            }
            guard let activeConverter = converter else { return }

            let ratio = targetFormat.sampleRate / monoSourceFormat.sampleRate
            let outputFrameCapacity = AVAudioFrameCount((Double(monoBuffer.frameLength) * ratio).rounded(.up) + 1)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
                return
            }

            var bufferConsumed = false
            var conversionError: NSError?
            let status = activeConverter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                if bufferConsumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                bufferConsumed = true
                inputStatus.pointee = .haveData
                return monoBuffer
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
            let yieldResult = continuation.yield(data)
            if case .enqueued = yieldResult {
                // Expected, common case.
            } else {
                logger.error("Microphone continuation.yield() did not enqueue: \(String(describing: yieldResult), privacy: .public)")
            }
        }

        // A route/format change (e.g. the system reconfiguring the default
        // input device) posts this notification; AVAudioEngine's own docs
        // note the engine and its taps can stop delivering audio when it
        // fires without an explicit error, so it's worth a log line if it
        // ever happens.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [logger] notification in
            logger.notice("AVAudioEngineConfigurationChange received: \(String(describing: notification), privacy: .public)")
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

        logger.notice("Microphone engine started")

        return stream
    }

    func stop() {
        guard engine.isRunning || continuation != nil else { return }
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }

    /// Manually mixes `buffer`'s channels down to mono by averaging them,
    /// entirely in code we can verify by reading it — see the call site for
    /// why we stopped trusting `AVAudioConverter.downmix` for this step.
    /// AVAudioEngine taps are always Float32, non-interleaved in practice
    /// (Apple's documented internal canonical format); this fails loudly via
    /// logging instead of guessing if that ever isn't true.
    private static func monoDownmix(of buffer: AVAudioPCMBuffer, logger: Logger) -> AVAudioPCMBuffer? {
        let sourceFormat = buffer.format
        guard sourceFormat.commonFormat == .pcmFormatFloat32, !sourceFormat.isInterleaved else {
            logger.error("Unexpected mic tap format (expected Float32 non-interleaved): \(sourceFormat.description, privacy: .public)")
            return nil
        }
        guard let sourceChannels = buffer.floatChannelData else { return nil }

        let channelCount = Int(sourceFormat.channelCount)
        let frameCount = Int(buffer.frameLength)

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: 1,
            interleaved: false
        ), let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
        let monoChannel = monoBuffer.floatChannelData?[0] else {
            return nil
        }

        if channelCount == 1 {
            monoChannel.update(from: sourceChannels[0], count: frameCount)
        } else {
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += sourceChannels[channel][frame]
                }
                monoChannel[frame] = sum / Float(channelCount)
            }
        }
        monoBuffer.frameLength = buffer.frameLength

        return monoBuffer
    }
}
