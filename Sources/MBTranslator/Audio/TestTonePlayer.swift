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
final class TestTonePlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let logger = Logger(subsystem: AppLogging.subsystem, category: "TestTonePlayer")

    func play(deviceID: AudioDeviceID) throws {
        engine.stop()
        engine.reset()

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

        if !engine.attachedNodes.contains(playerNode) {
            engine.attach(playerNode)
        }
        engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)

        try route(to: deviceID)

        do {
            try engine.start()
        } catch {
            logger.error("Failed to start engine: \(error.localizedDescription, privacy: .public)")
            throw TestTonePlaybackError.engineStartFailed
        }

        playerNode.scheduleFile(file, at: nil)
        playerNode.play()
    }

    func stop() {
        playerNode.stop()
        engine.stop()
    }

    /// Must be called after the output node's underlying audio unit exists
    /// (i.e. after attaching/connecting at least one node) but before
    /// `engine.start()`.
    private func route(to deviceID: AudioDeviceID) throws {
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
