import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            APIKeysSettingsTab()
                .tabItem {
                    Label("Klucze API", systemImage: "key.fill")
                }

            AudioSettingsTab()
                .tabItem {
                    Label("Audio", systemImage: "speaker.wave.2.fill")
                }
        }
        .frame(width: 480, height: 460)
    }
}
