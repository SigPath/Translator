import AVFoundation
import CoreAudio
import os

enum ProcessTapError: Error, LocalizedError {
    case sourceNotFound(CaptureSource)
    case tapCreationFailed(OSStatus)
    case tapFormatUnavailable(OSStatus)
    case unsupportedTapFormat
    case outputDeviceUnavailable(OSStatus)
    case aggregateDeviceFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case startFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .sourceNotFound(let source):
            source.notFoundHint
        case .tapCreationFailed(let status):
            "\(String(localized: "Nie udało się utworzyć przechwytywania audio Teams")) (OSStatus \(status))"
        case .tapFormatUnavailable(let status):
            "\(String(localized: "Nie udało się odczytać formatu audio Teams")) (OSStatus \(status))"
        case .unsupportedTapFormat:
            String(localized: "Nieobsługiwany format audio przechwytywania Teams")
        case .outputDeviceUnavailable(let status):
            "\(String(localized: "Nie udało się ustalić domyślnego wyjścia audio")) (OSStatus \(status))"
        case .aggregateDeviceFailed(let status):
            "\(String(localized: "Nie udało się utworzyć urządzenia przechwytywania")) (OSStatus \(status))"
        case .ioProcFailed(let status), .startFailed(let status):
            "\(String(localized: "Nie udało się uruchomić przechwytywania audio Teams")) (OSStatus \(status))"
        }
    }
}

/// M4 "tor B": captures the audio a set of processes (Microsoft Teams — the
/// remote party's voice) plays, via a Core Audio **process tap**
/// (`AudioHardwareCreateProcessTap`, macOS 14.2+), and yields it as PCM16
/// mono 16 kHz ~100 ms chunks — the same stream shape `MicrophoneCapture`
/// produces, so it feeds the same `AzureSpeechTranslationService`.
///
/// A process tap has no IO of its own: it's exposed as an input stream of a
/// private *aggregate device*, whose IO proc we drive. `.unmuted` keeps
/// Teams audible to the user (we only listen).
///
/// Needs the "System Audio Recording" privacy permission
/// (`NSAudioCaptureUsageDescription`). Without it macOS still lets the tap
/// be created but delivers silence — see docs/DECISIONS.md, "M4".
///
/// Not actor-isolated; the IO block only touches values captured locally.
final class ProcessTapCapture: @unchecked Sendable {
    private let logger = Logger(subsystem: AppLogging.subsystem, category: "ProcessTapCapture")
    private let ioQueue = DispatchQueue(label: "pl.mbgroup.translator.processtap", qos: .userInitiated)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<Data>.Continuation?

    func start(source: CaptureSource, processObjectIDs: [AudioObjectID]) throws -> AsyncStream<Data> {
        stop(reason: "start() called (fresh session or restart)")
        guard !processObjectIDs.isEmpty else { throw ProcessTapError.sourceNotFound(source) }

        do {
            let stream = try startThrowing(processObjectIDs: processObjectIDs)
            logger.notice("Process tap started for \(processObjectIDs.count, privacy: .public) \(source.rawValue, privacy: .public) audio process(es)")
            return stream
        } catch {
            teardown()
            throw error
        }
    }

    private func startThrowing(processObjectIDs: [AudioObjectID]) throws -> AsyncStream<Data> {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.name = "MB Translator — tor B"
        // `muteBehavior` is left at its documented default, `CATapUnmuted`:
        // Teams stays audible to the user, we only listen.
        description.isPrivate = true

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw ProcessTapError.tapCreationFailed(status) }

        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &format)
        guard status == noErr else { throw ProcessTapError.tapFormatUnavailable(status) }
        logger.notice("Tap format: \(format.mSampleRate, privacy: .public) Hz, \(format.mChannelsPerFrame, privacy: .public) ch, flags=\(format.mFormatFlags, privacy: .public)")

        guard let converter = PCM16MonoConverter(sourceFormat: format) else {
            throw ProcessTapError.unsupportedTapFormat
        }

        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MB Translator Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDeviceID)
        guard status == noErr else { throw ProcessTapError.aggregateDeviceFailed(status) }

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation

        let logger = self.logger
        var didLogFirstBuffer = false
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, ioQueue) { _, inputData, _, _, _ in
            if !didLogFirstBuffer {
                didLogFirstBuffer = true
                logger.notice("First tapped audio buffer received")
            }
            for chunk in converter.process(inputData) {
                continuation.yield(chunk)
            }
        }
        guard status == noErr, ioProcID != nil else { throw ProcessTapError.ioProcFailed(status) }

        status = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard status == noErr else { throw ProcessTapError.startFailed(status) }

        return stream
    }

    /// `reason` is required so every call site stays self-documenting in
    /// the log — same convention as `MicrophoneCapture.stop(reason:)`.
    func stop(reason: String) {
        guard continuation != nil || tapID != AudioObjectID(kAudioObjectUnknown) else { return }
        logger.notice("Process tap stopping (\(reason, privacy: .public))")
        teardown()
    }

    private func teardown() {
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            if let ioProcID {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        continuation?.finish()
        continuation = nil
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr else { throw ProcessTapError.outputDeviceUnavailable(status) }

        var uid: CFString?
        size = UInt32(MemoryLayout<CFString?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let uid else { throw ProcessTapError.outputDeviceUnavailable(status) }
        return uid as String
    }
}
