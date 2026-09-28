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

    deinit {
        // TEMP (M2a debug): if this ever prints while you're still speaking
        // (before clicking Zatrzymaj), the instance itself is being torn
        // down — that's the smoking gun for a lifecycle bug, as opposed to
        // something inside start()/stop() finishing the stream on purpose.
        print("[MicrophoneCapture] DEINIT")
    }

    func start() throws -> AsyncStream<Data> {
        print("[MicrophoneCapture] start() called") // TEMP (M2a debug) — remove once confirmed working
        stop(reason: "start() clearing any previous session")

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
        var tapCallCount = 0 // TEMP (M2a debug): proves whether the tap fires more than once at all.

        inputNode.installTap(onBus: 0, bufferSize: 1600, format: nil) { buffer, _ in
            let sourceFormat = buffer.format
            tapCallCount += 1
            // TEMP (M2a debug): logging every call (not just the first) — if
            // this stops appearing while you're still speaking, Core Audio
            // itself stopped calling the tap (engine/route issue). If it
            // keeps appearing but "audio source ended" still prints, the bug
            // is downstream of this callback (the yield/continuation or the
            // consumer side), not here.
            print("[MicrophoneCapture] tap call #\(tapCallCount): frameLength=\(buffer.frameLength) format=\(sourceFormat)")
            if tapCallCount == 1 {
                logger.notice("First microphone buffer received")
            }

            if converter == nil || converterSourceFormat != sourceFormat {
                converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
                converterSourceFormat = sourceFormat
                if converter == nil {
                    logger.error("Could not create converter for mic format: \(sourceFormat.description, privacy: .public)")
                }
            }
            guard let activeConverter = converter else { return }

            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let outputFrameCapacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 1)
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
            // TEMP (M2a debug): `yield` can silently drop data if the stream
            // was already finished (`.terminated`) or over the buffering
            // limit (`.dropped`) — logging the result rules that in/out.
            let yieldResult = continuation.yield(data)
            if case .enqueued = yieldResult {
                // Expected, common case — don't spam the console for it.
            } else {
                print("[MicrophoneCapture] tap call #\(tapCallCount): continuation.yield() returned \(yieldResult)")
            }
        }

        // TEMP (M2a debug): a route/format change (e.g. the system
        // reconfiguring the default input device) posts this notification;
        // AVAudioEngine's own docs note the engine and its taps can stop
        // delivering audio when it fires without an explicit error. Logging
        // it tells us if that's happening here.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { notification in
            print("[MicrophoneCapture] AVAudioEngineConfigurationChange received: \(notification)")
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            self.continuation = nil
            print("[MicrophoneCapture] engine.start() threw: \(error)") // TEMP (M2a debug)
            logger.error("Failed to start audio engine: \(error.localizedDescription, privacy: .public)")
            throw MicrophoneCaptureError.engineStartFailed
        }

        print("[MicrophoneCapture] engine.start() succeeded, tap installed") // TEMP (M2a debug)
        logger.notice("Microphone engine started")

        return stream
    }

    func stop() {
        stop(reason: "external stop() called")
    }

    private func stop(reason: String) {
        // TEMP (M2a debug): logging every call (including short-circuited
        // ones) tells us definitively whether/when `stop()` actually runs
        // its body and finishes the continuation, instead of guessing from
        // symptoms downstream.
        print("[MicrophoneCapture] stop(reason: \(reason)) called — engine.isRunning=\(engine.isRunning) continuation!=nil=\(continuation != nil)")
        guard engine.isRunning || continuation != nil else { return }
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        print("[MicrophoneCapture] stop(reason: \(reason)) finishing continuation now") // TEMP (M2a debug)
        continuation?.finish()
        continuation = nil
    }
}
