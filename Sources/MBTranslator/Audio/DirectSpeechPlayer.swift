import AudioToolbox
import AVFoundation
import os

/// Routes ElevenLabs-synthesized speech to a specific Core Audio output
/// device (VB-Cable), reusing the exact device-routing pattern established
/// and verified on real hardware in `TestTonePlayer` (M1) — see
/// `CoreAudioOutputRouting` for the shared steps.
///
/// Unlike `TestTonePlayer` (one-shot playback of a single bundled file),
/// this stays alive for an entire "mów bezpośrednio" session and plays
/// multiple clips back-to-back as they arrive from `DirectSpeechController`.
/// v1 happy path (per project scope): a simple FIFO queue, no
/// mixing/interruption — if utterances overlap in time, the later one just
/// waits for the earlier one to finish playing.
///
/// `@MainActor` for the same reason as `TestTonePlayer`: real mutable
/// engine/node state, only ever driven from the main-actor translation
/// pipeline.
@MainActor
final class DirectSpeechPlayer {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var connectedFormat: AVAudioFormat?
    private var queue: [Data] = []
    private var isProcessingQueue = false
    private let logger = Logger(subsystem: AppLogging.subsystem, category: "DirectSpeechPlayer")

    func start(deviceID: AudioDeviceID) async throws {
        stop()

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()

        try CoreAudioOutputRouting.route(engine: engine, to: deviceID)
        // This engine only ever plays audio out — disable its input scope
        // explicitly, or it silently also opens a second, competing
        // microphone stream alongside `MicrophoneCapture`'s own engine (see
        // `disableInput`'s doc comment).
        CoreAudioOutputRouting.disableInput(engine: engine, logger: logger)
        CoreAudioOutputRouting.matchBufferSize(engine: engine, to: deviceID, logger: logger)

        engine.attach(playerNode)

        let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw CoreAudioOutputRoutingError.deviceRoutingFailed(OSStatus(kAudio_ParamError))
        }

        // `AVAudioPlayerNode.play()` throws "player started when in a
        // disconnected state" if the node has no output connection yet —
        // it must be connected to *something* before `play()` below, even
        // though we don't know the first clip's real decoded format until
        // it actually arrives (see `connectIfNeeded`). This placeholder
        // matches what ElevenLabs' fixed `mp3_44100_128` output_format
        // decodes to in the typical case (44.1kHz mono); `connectIfNeeded`
        // reconnects to each clip's *actual* format later if it differs —
        // AVAudioEngine supports reconnecting nodes while running — so this
        // initial guess doesn't need to be exact, just non-nil.
        let placeholderFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)
        engine.connect(playerNode, to: engine.mainMixerNode, format: placeholderFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardwareFormat)
        engine.prepare()

        try await CoreAudioOutputRouting.startWithRetries(engine, logger: logger)

        self.engine = engine
        self.playerNode = playerNode
        self.connectedFormat = placeholderFormat
        playerNode.play()
    }

    func stop() {
        queue.removeAll()
        isProcessingQueue = false
        playerNode?.stop()
        engine?.stop()
        playerNode = nil
        engine = nil
        connectedFormat = nil
    }

    /// Appends `audioData` (MP3 bytes from ElevenLabs) to the FIFO queue and
    /// kicks off processing if nothing is currently playing. No-op (logged)
    /// if `start(deviceID:)` hasn't succeeded yet — this is a fire-and-forget
    /// call from `DirectSpeechController`, which always awaits `start`
    /// first, so this should only trip if `stop()` raced it.
    func enqueue(_ audioData: Data) {
        guard engine != nil, playerNode != nil else {
            logger.error("enqueue called with no active engine — dropping clip")
            return
        }
        queue.append(audioData)
        processNextIfNeeded()
    }

    private func processNextIfNeeded() {
        guard !isProcessingQueue, !queue.isEmpty, let playerNode else { return }
        isProcessingQueue = true
        let data = queue.removeFirst()

        Task {
            await play(data, on: playerNode)
            isProcessingQueue = false
            processNextIfNeeded()
        }
    }

    /// Writes the clip to a temp file and plays it through `AVAudioFile`
    /// (same mechanism `TestTonePlayer` uses for its bundled WAV) rather
    /// than parsing MP3 frames ourselves — Core Audio's own decoder handles
    /// that. The temp file is removed once playback completes.
    private func play(_ data: Data, on playerNode: AVAudioPlayerNode) async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("mp3")

        do {
            try data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let file = try AVAudioFile(forReading: tempURL)
            try connectIfNeeded(format: file.processingFormat)

            await withCheckedContinuation { continuation in
                playerNode.scheduleFile(file, at: nil) {
                    continuation.resume()
                }
            }
        } catch {
            logger.error("Playback of synthesized clip failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The playerNode→mixer connection format must match what's about to be
    /// scheduled (see `TestTonePlayer`'s doc comment on the same
    /// requirement — the mixer resamples this connection internally, so the
    /// file's own format is fine here). Done lazily on the first clip, since
    /// ElevenLabs' decoded response format isn't known until then, and
    /// reused afterwards — every request asks for the same `output_format`,
    /// so it won't actually change between clips in practice.
    private func connectIfNeeded(format: AVAudioFormat) throws {
        guard let engine, let playerNode else {
            throw CoreAudioOutputRoutingError.engineStartFailed
        }
        if let connectedFormat, connectedFormat.isEqual(format) {
            return
        }
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        connectedFormat = format
    }
}
