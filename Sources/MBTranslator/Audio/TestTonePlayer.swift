import AudioToolbox
import AVFoundation
import os

enum TestTonePlaybackError: Error, LocalizedError {
    case resourceMissing
    case fileLoadFailed
    case deviceRoutingFailed(OSStatus)
    case engineStartFailed

    var errorDescription: String? {
        switch self {
        case .resourceMissing:
            String(localized: "Nie znaleziono pliku testowego w zasobach aplikacji")
        case .fileLoadFailed:
            String(localized: "Nie udało się wczytać pliku testowego")
        case .deviceRoutingFailed(let status):
            "\(String(localized: "Nie udało się skierować dźwięku na wybrane urządzenie")) (\(status))"
        case .engineStartFailed:
            String(localized: "Nie udało się uruchomić silnika audio")
        }
    }
}

/// Plays a short bundled test tone routed to a specific Core Audio output
/// device (e.g. VB-Cable), independent of the system's default output.
/// Used to manually verify device routing in Teams/WhatsApp/Zoom (M1) —
/// this bypasses the translation pipeline entirely, which doesn't exist yet.
/// Not actor-isolated: it's only ever driven from SwiftUI's main-actor UI
/// code (button taps), so no cross-actor use to guard against.
///
/// A fresh `AVAudioEngine`/`AVAudioPlayerNode` pair is built on every
/// `play(deviceID:)` call rather than reused. Before anything else touches
/// format negotiation (attaching nodes, reading `outputFormat(forBus:)`,
/// connecting the mixer to the output), this:
///  1. sets the output device (`kAudioOutputUnitProperty_CurrentDevice`),
///  2. reads that device's *currently active* IO buffer frame size
///     (`kAudioDevicePropertyBufferFrameSize`) and matches our output
///     unit's `kAudioUnitProperty_MaximumFramesPerSlice` to it, instead of
///     assuming our own default.
/// Skipping either step leaves the mixer→output connection wired for
/// whatever device/buffer size was current at attach time, which then
/// fails or glitches when starting IO on a *shared* virtual device another
/// client (e.g. Teams, WhatsApp) is already actively running with its own
/// negotiated format/buffer size — this is what surfaces in the console as
/// `HALC_ProxyIOContext::_StartIO` error 35, or downstream IO work-loop
/// overload/out-of-order messages once a second client's buffer size
/// disagrees with the first's. VB-Cable's own docs note it has an internal
/// buffering scheme (2048-sample latency) that connected clients need to
/// work within, which is consistent with buffer-size mismatches being more
/// disruptive on it than a plain sample-rate difference alone.
/// `engine.start()` is retried a couple of times with a short delay, since
/// a device mid-renegotiation between two clients can fail transiently
/// before settling.
final class TestTonePlayer {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let logger = Logger(subsystem: AppLogging.subsystem, category: "TestTonePlayer")

    func play(deviceID: AudioDeviceID) async throws {
        stop()

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()

        // Must happen first, before anything else queries or negotiates
        // format on this engine.
        try route(engine: engine, to: deviceID)
        matchBufferSize(engine: engine, to: deviceID)

        guard let url = Bundle.main.url(forResource: "TestTone", withExtension: "wav") else {
            throw TestTonePlaybackError.resourceMissing
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            logger.error("Failed to load test tone: \(error.localizedDescription, privacy: .public)")
            throw TestTonePlaybackError.fileLoadFailed
        }

        engine.attach(playerNode)

        // Read the hardware format only now, after switching devices, so it
        // reflects the selected device's actual current format (its own
        // nominal rate, or whatever rate another client already has it
        // running at) rather than a stale/default one.
        let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw TestTonePlaybackError.deviceRoutingFailed(OSStatus(kAudio_ParamError))
        }

        // The mixer resamples this connection internally, so the file's own
        // format is fine here; it's the mixer→output connection below that
        // must match hardware exactly.
        engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardwareFormat)
        engine.prepare()

        try await startWithRetries(engine)

        self.engine = engine
        self.playerNode = playerNode

        // Explicit `completionHandler: nil` forces the classic
        // fire-and-forget overload. `scheduleFile(_:at:)` without it also
        // matches a newer `async throws` overload (defaults to suspending
        // until playback finishes) - now that `play(deviceID:)` itself is
        // `async`, that overload becomes a viable, silently-preferred match
        // and the call needs `await`. We don't want to await full playback
        // here, so we disambiguate to the non-async overload instead.
        playerNode.scheduleFile(file, at: nil, completionHandler: nil)
        playerNode.play()
    }

    func stop() {
        playerNode?.stop()
        engine?.stop()
        playerNode = nil
        engine = nil
    }

    /// Two retries (150 ms, then 400 ms) after the first attempt, for the
    /// case where a shared virtual device is mid-renegotiation between two
    /// IO clients and briefly refuses `StartIO`.
    private func startWithRetries(_ engine: AVAudioEngine) async throws {
        let retryDelaysMilliseconds: [UInt64] = [0, 150, 400]
        var lastError: Error?

        for (attempt, delayMilliseconds) in retryDelaysMilliseconds.enumerated() {
            if delayMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            }
            do {
                try engine.start()
                return
            } catch {
                lastError = error
                logger.error("engine.start() attempt \(attempt + 1) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        logger.error("engine.start() failed after retries: \(lastError?.localizedDescription ?? "?", privacy: .public)")
        throw TestTonePlaybackError.engineStartFailed
    }

    /// Must be the first thing done on a freshly created engine, before any
    /// attach/connect or format read (see class-level doc comment).
    private func route(engine: AVAudioEngine, to deviceID: AudioDeviceID) throws {
        guard let outputUnit = engine.outputNode.audioUnit else {
            throw TestTonePlaybackError.deviceRoutingFailed(OSStatus(kAudio_ParamError))
        }

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw TestTonePlaybackError.deviceRoutingFailed(status)
        }
    }

    /// Reads the device's currently active IO buffer frame size and adapts
    /// our output unit to it, rather than starting with our own default and
    /// risking a mismatch against a client that's already running on this
    /// device. Best-effort: failing to read/set this is logged but not
    /// fatal, since `startWithRetries` covers residual `StartIO` failures.
    private func matchBufferSize(engine: AVAudioEngine, to deviceID: AudioDeviceID) {
        guard let outputUnit = engine.outputNode.audioUnit else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bufferFrameSize: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let readStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &bufferFrameSize)
        guard readStatus == noErr, bufferFrameSize > 0 else {
            logger.error("Could not read device buffer frame size (status \(readStatus)); using engine default")
            return
        }

        let setStatus = AudioUnitSetProperty(
            outputUnit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &bufferFrameSize,
            UInt32(MemoryLayout<UInt32>.size)
        )
        if setStatus != noErr {
            logger.error("Failed to match device buffer frame size (\(bufferFrameSize) frames): \(setStatus)")
        }
    }
}
