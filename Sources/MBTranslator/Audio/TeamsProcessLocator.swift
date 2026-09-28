import CoreAudio
import Foundation

/// Finds Microsoft Teams among the processes Core Audio knows about, for
/// the M4 process tap. Matches on bundle ID *prefix* `com.microsoft.teams`
/// rather than one exact ID: new Teams (`com.microsoft.teams2`) and classic
/// Teams (`com.microsoft.teams`) differ, and Teams renders call audio from
/// helper processes (e.g. `com.microsoft.teams2.modulehost`) that carry the
/// same prefix — tapping only the main process would miss them.
///
/// A process only appears in Core Audio's list once it has talked to the
/// audio system, so Teams must already be running (ideally in a call).
enum TeamsProcessLocator {
    static func isTeamsBundleID(_ bundleID: String) -> Bool {
        bundleID.lowercased().hasPrefix("com.microsoft.teams")
    }

    /// Core Audio process objects belonging to Teams; empty if none.
    static func teamsAudioProcessObjectIDs() -> [AudioObjectID] {
        allAudioProcessObjectIDs().filter { id in
            bundleID(of: id).map(isTeamsBundleID) ?? false
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
