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
/// Not actor-isolated: it's only ever driven synchronously from SwiftUI's
/// main-actor UI code (button taps), so no cross-actor use to guard against.
///
/// A fresh `AVAudioEngine`/`AVAudioPlayerNode` pair is built on every
/// `play(deviceID:)` call rather than reused. The device must be set on the
/// output unit *before* anything else touches format negotiation (attaching
/// nodes, reading `outputFormat(forBus:)`, connecting the mixer to the
/// output) - otherwise the mixer→output connection locks in whatever
/// format was current at attach time (e.g. the previous device, or
/// whatever the engine defaulted to), and `engine.start()` then tries to
/// start IO on the new device with a mismatched format. That mismatch is
/// exactly what surfaces as `HALC_ProxyIOContext::_StartIO` failing with
/// error 35 in the console - most visible with a shared virtual device
/// like VB-Cable, whose nominal sample rate may already be locked in by
/// another running client (e.g. Teams).
final class TestTonePlayer {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let logger = Logger(subsystem: AppLogging.subsystem, category: "TestTonePlayer")

    func play(deviceID: AudioDeviceID) throws {
        stop()

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()

        // Must happen first, before anything else queries or negotiates
        // format on this engine.
        try route(engine: engine, to: deviceID)

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

        do {
            engine.prepare()
            try engine.start()
        } catch {
            logger.error("Failed to start engine: \(error.localizedDescription, privacy: .public)")
            throw TestTonePlaybackError.engineStartFailed
        }

        self.engine = engine
        self.playerNode = playerNode

        playerNode.scheduleFile(file, at: nil)
        playerNode.play()
    }

    func stop() {
        playerNode?.stop()
        engine?.stop()
        playerNode = nil
        engine = nil
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
}
