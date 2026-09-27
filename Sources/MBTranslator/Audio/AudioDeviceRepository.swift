import CoreAudio
import Foundation

enum AudioDeviceError: Error, LocalizedError {
    case coreAudioError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .coreAudioError(let status):
            "\(String(localized: "Błąd Core Audio")) (\(status))"
        }
    }
}

/// Thin wrapper around Core Audio's `AudioObject` property APIs for
/// enumerating physical and virtual output/input devices (e.g. VB-Cable).
enum AudioDeviceRepository {
    static func allDevices() throws -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else { throw AudioDeviceError.coreAudioError(status) }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard deviceCount > 0 else { return [] }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { throw AudioDeviceError.coreAudioError(status) }

        return deviceIDs.compactMap(device(for:))
    }

    private static func device(for deviceID: AudioDeviceID) -> AudioDevice? {
        guard let name = stringProperty(deviceID: deviceID, selector: kAudioObjectPropertyName),
              let uid = stringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID)
        else {
            return nil
        }

        return AudioDevice(
            id: deviceID,
            uid: uid,
            name: name,
            outputChannelCount: channelCount(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput),
            inputChannelCount: channelCount(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput)
        )
    }

    private static func stringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var unmanagedString: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanagedString) { pointer -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let unmanagedString else { return nil }
        return unmanagedString.takeRetainedValue() as String
    }

    private static func channelCount(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return 0 }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }

        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferListPointer)
        guard status == noErr else { return 0 }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
