import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            APIKeysSettingsTab()
                .tabItem {
                    Label("Klucze API", systemImage: "key.fill")
                }
        }
        .frame(width: 480, height: 320)
    }
}
