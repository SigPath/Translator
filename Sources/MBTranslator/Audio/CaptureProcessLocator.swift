import CoreAudio
import Foundation

/// Finds the Core Audio processes of a `CaptureSource` (Microsoft Teams,
/// or — as a test aid — a web browser) for the M4 process tap. Matching is
/// done by bundle-ID prefix, see `CaptureSource.bundleIDPrefixes`.
///
/// A process only appears in Core Audio's list once it has talked to the
/// audio system, so the source must already be running and have played
/// audio (Teams in a call, a browser tab with a video playing).
enum CaptureProcessLocator {
    struct Match {
        let objectID: AudioObjectID
        let bundleID: String
    }

    /// Core Audio processes belonging to `source`; empty if none.
    static func audioProcesses(for source: CaptureSource) -> [Match] {
        allAudioProcessObjectIDs().compactMap { id in
            guard let bundleID = bundleID(of: id), source.matches(bundleID: bundleID) else { return nil }
            return Match(objectID: id, bundleID: bundleID)
        }
    }

    private static func allAudioProcessObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(process, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
