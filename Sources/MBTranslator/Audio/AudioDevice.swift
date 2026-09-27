import CoreAudio

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let outputChannelCount: Int
    let inputChannelCount: Int

    var hasOutput: Bool { outputChannelCount > 0 }
    var hasInput: Bool { inputChannelCount > 0 }

    /// Heuristic match for VB-Cable for Mac, used for first-run auto-detection.
    /// BlackHole and other virtual devices are still listed and selectable
    /// manually, just not auto-picked.
    var looksLikeVBCable: Bool {
        name.localizedCaseInsensitiveContains("VB-Cable")
            || name.localizedCaseInsensitiveContains("VB-Audio")
    }
}
