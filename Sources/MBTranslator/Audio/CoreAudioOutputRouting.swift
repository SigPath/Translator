import AudioToolbox
import AVFoundation
import os

enum CoreAudioOutputRoutingError: Error, LocalizedError {
    case deviceRoutingFailed(OSStatus)
    case engineStartFailed

    var errorDescription: String? {
        switch self {
        case .deviceRoutingFailed(let status):
            "\(String(localized: "Nie udało się skierować dźwięku na wybrane urządzenie")) (\(status))"
        case .engineStartFailed:
            String(localized: "Nie udało się uruchomić silnika audio")
        }
    }
}

/// Shared Core Audio output-device routing steps, factored out of the
/// pattern established and verified on real hardware in `TestTonePlayer`
/// (M1), so other players (e.g. `DirectSpeechPlayer`, M3) can reuse the
/// exact same sequence instead of re-deriving it. `TestTonePlayer` itself is
/// intentionally left untouched — it's a confirmed-working reference, not
/// worth risking a regression in to deduplicate a few dozen lines.
///
/// See `TestTonePlayer`'s doc comment for the full rationale (buffer size
/// mismatch against another client sharing the device → `HALC_ProxyIOContext
/// ::_StartIO` error 35, etc).
enum CoreAudioOutputRouting {
    /// Must be the first thing done on a freshly created engine, before any
    /// attach/connect or format read.
    static func route(engine: AVAudioEngine, to deviceID: AudioDeviceID) throws {
        guard let outputUnit = engine.outputNode.audioUnit else {
            throw CoreAudioOutputRoutingError.deviceRoutingFailed(OSStatus(kAudio_ParamError))
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
            throw CoreAudioOutputRoutingError.deviceRoutingFailed(status)
        }
    }

    /// A fresh `AVAudioEngine`'s underlying I/O unit has **both** input and
    /// output scopes enabled by default — even for an engine that only ever
    /// touches `outputNode` and never installs a tap on `inputNode`. Left
    /// enabled, a playback-only engine like this one silently also opens a
    /// microphone input stream of its own, alongside whatever engine (e.g.
    /// `MicrophoneCapture`) is *actually* capturing the mic for real — two
    /// separate `AVAudioEngine`s both driving the same physical input
    /// device's real-time IO thread. Confirmed on real hardware (a MacBook
    /// Air) as the cause of a case where the microphone pipeline went
    /// silently dead right after the first ElevenLabs clip played: Core
    /// Audio logged `HALC_ProxyIOContext::IOWorkLoop: skipping cycle due to
    /// overload` / `received an out of order message` at exactly that
    /// moment, and no further speech was recognized afterwards even though
    /// the user kept talking — see docs/DECISIONS.md, "Follow-up: mikrofon
    /// milknie po pierwszym odtworzeniu TTS (M3)".
    ///
    /// Must be called before the engine is prepared/started (same
    /// constraint as `route(engine:to:)`) — disabling IO on a scope after
    /// the unit is initialized has no effect.
    static func disableInput(engine: AVAudioEngine, logger: Logger) {
        guard let outputUnit = engine.outputNode.audioUnit else { return }

        var disableInput: UInt32 = 0
        let status = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1, // input element of the combined HAL I/O unit
            &disableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        if status != noErr {
            logger.error("Failed to disable input IO on playback-only engine: \(status)")
        }
    }

    /// Reads the device's currently active IO buffer frame size and adapts
    /// our output unit to it. Best-effort: failing to read/set this is
    /// logged but not fatal, since `startWithRetries` covers residual
    /// `StartIO` failures.
    static func matchBufferSize(engine: AVAudioEngine, to deviceID: AudioDeviceID, logger: Logger) {
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

    /// Two retries (150 ms, then 400 ms) after the first attempt, for the
    /// case where a shared virtual device is mid-renegotiation between two
    /// IO clients and briefly refuses `StartIO`.
    static func startWithRetries(_ engine: AVAudioEngine, logger: Logger) async throws {
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
        throw CoreAudioOutputRoutingError.engineStartFailed
    }
}
