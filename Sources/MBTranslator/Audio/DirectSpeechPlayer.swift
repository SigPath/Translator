import AudioToolbox
import AVFoundation
import os

/// Routes ElevenLabs-synthesized speech to a specific Core Audio output
/// device (VB-Cable), reusing the exact device-routing pattern established
/// and verified on real hardware in `TestTonePlayer` (M1) — see
/// `CoreAudioOutputRouting` for the shared steps.
///
/// A **fresh, transient `AVAudioEngine` per clip** — created right before
/// playing, torn down right after — same as `TestTonePlayer`, not a single
/// engine kept alive for the whole "mów bezpośrednio" session (an earlier
/// version of this class did that; changed after real-hardware testing
/// showed *any* concurrent second engine, even with input correctly
/// disabled, could still starve `MicrophoneCapture`'s real-time IO thread
/// badly enough to kill it permanently — see docs/DECISIONS.md, "Follow-up:
/// dwa równoległe silniki audio to za dużo dla tego Maca"). `willPlay`/
/// `didFinishPlaying` bracket each clip's engine lifetime precisely, so
/// `TranslationPipelineController` can pause `MicrophoneCapture` for that
/// window and resume it right after — the two engines' IO now never
/// overlaps at all, rather than trying to make them coexist.
///
/// v1 happy path (per project scope): a simple FIFO queue, no
/// mixing/interruption — if utterances overlap in time, the later one just
/// waits for the earlier one to finish playing.
///
/// `@MainActor` for the same reason as `TestTonePlayer`: real mutable
/// state, only ever driven from the main-actor translation pipeline.
@MainActor
final class DirectSpeechPlayer {
    private var deviceID: AudioDeviceID?
    private var queue: [Data] = []
    private var isProcessingQueue = false
    private let logger = Logger(subsystem: AppLogging.subsystem, category: "DirectSpeechPlayer")

    /// Called immediately before each clip's engine starts, and again right
    /// after it stops — `TranslationPipelineController` wires these to
    /// `MicrophoneCapture.pause()`/`.resume()`.
    var willPlay: (() -> Void)?
    var didFinishPlaying: (() -> Void)?

    /// Just records which device to use — the actual engine is created
    /// fresh per clip in `play(_:)`, so unlike the old session-long design
    /// this never needs to be `async throws`.
    func configure(deviceID: AudioDeviceID) {
        self.deviceID = deviceID
    }

    func stop() {
        queue.removeAll()
        isProcessingQueue = false
        deviceID = nil
    }

    /// Appends `audioData` (MP3 bytes from ElevenLabs) to the FIFO queue and
    /// kicks off processing if nothing is currently playing. No-op (logged)
    /// if `configure(deviceID:)` hasn't been called yet.
    func enqueue(_ audioData: Data) {
        guard deviceID != nil else {
            logger.error("enqueue called before configure(deviceID:) — dropping clip")
            return
        }
        queue.append(audioData)
        processNextIfNeeded()
    }

    private func processNextIfNeeded() {
        guard !isProcessingQueue, !queue.isEmpty, let deviceID else { return }
        isProcessingQueue = true
        let data = queue.removeFirst()

        Task {
            await play(data, deviceID: deviceID)
            isProcessingQueue = false
            processNextIfNeeded()
        }
    }

    /// Writes the clip to a temp file and plays it through `AVAudioFile`
    /// (same mechanism `TestTonePlayer` uses for its bundled WAV) rather
    /// than parsing MP3 frames ourselves — Core Audio's own decoder handles
    /// that. Builds and tears down a fresh engine around exactly this one
    /// clip, bracketed by `willPlay`/`didFinishPlaying`.
    private func play(_ data: Data, deviceID: AudioDeviceID) async {
        willPlay?()
        defer { didFinishPlaying?() }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("mp3")

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()

        do {
            try data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let file = try AVAudioFile(forReading: tempURL)

            try CoreAudioOutputRouting.route(engine: engine, to: deviceID)
            // This engine only ever plays audio out — disable its input
            // scope explicitly, or it silently also opens a second,
            // competing microphone stream alongside `MicrophoneCapture`'s
            // own engine (see `disableInput`'s doc comment). Kept even
            // though the two engines no longer run at the same time any
            // more (see this type's doc comment) — still correct practice
            // for a playback-only engine, and cheap insurance.
            CoreAudioOutputRouting.disableInput(engine: engine, logger: logger)
            CoreAudioOutputRouting.matchBufferSize(engine: engine, to: deviceID, logger: logger)

            engine.attach(playerNode)

            let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
            guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
                throw CoreAudioOutputRoutingError.deviceRoutingFailed(OSStatus(kAudio_ParamError))
            }

            // Unlike the old session-long design, the real file (and so its
            // real `processingFormat`) is already known here, before
            // `play()` is ever called — no placeholder-format dance needed.
            engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardwareFormat)
            engine.prepare()

            try await CoreAudioOutputRouting.startWithRetries(engine, logger: logger)
            playerNode.play()

            await withCheckedContinuation { continuation in
                playerNode.scheduleFile(file, at: nil) {
                    continuation.resume()
                }
            }
        } catch {
            logger.error("Playback of synthesized clip failed: \(error.localizedDescription, privacy: .public)")
        }

        playerNode.stop()
        engine.stop()
    }
}
