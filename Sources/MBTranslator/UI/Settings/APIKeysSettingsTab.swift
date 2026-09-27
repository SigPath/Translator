import SwiftUI

struct APIKeysSettingsTab: View {
    @State private var deepLKey: String = ""
    @State private var elevenLabsKey: String = ""
    @State private var deepLTestResult: ConnectionTestResult?
    @State private var elevenLabsTestResult: ConnectionTestResult?
    @State private var deepLSaveError: String?
    @State private var elevenLabsSaveError: String?
    @State private var isTestingDeepL = false
    @State private var isTestingElevenLabs = false

    private let keychain = KeychainStore.shared
    private let tester = APIConnectionTester()

    var body: some View {
        Form {
            Section("DeepL") {
                SecureField("Klucz API DeepL", text: $deepLKey)
                HStack {
                    Button("Zapisz") { save(.deepL) }
                    Button("Testuj połączenie") { Task { await testConnection(.deepL) } }
                        .disabled(deepLKey.isEmpty || isTestingDeepL)
                    statusView(isTesting: isTestingDeepL, result: deepLTestResult)
                }
                if let deepLSaveError {
                    Text(deepLSaveError).foregroundStyle(.red).font(.caption)
                }
            }

            Section("ElevenLabs") {
                SecureField("Klucz API ElevenLabs", text: $elevenLabsKey)
                HStack {
                    Button("Zapisz") { save(.elevenLabs) }
                    Button("Testuj połączenie") { Task { await testConnection(.elevenLabs) } }
                        .disabled(elevenLabsKey.isEmpty || isTestingElevenLabs)
                    statusView(isTesting: isTestingElevenLabs, result: elevenLabsTestResult)
                }
                if let elevenLabsSaveError {
                    Text(elevenLabsSaveError).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .padding(20)
        .task {
            await loadStoredKeys()
        }
    }

    @ViewBuilder
    private func statusView(isTesting: Bool, result: ConnectionTestResult?) -> some View {
        if isTesting {
            ProgressView().controlSize(.small)
        } else if let result {
            switch result {
            case .success:
                Label("Połączenie OK", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private enum Provider {
        case deepL
        case elevenLabs
    }

    private func save(_ provider: Provider) {
        Task {
            do {
                switch provider {
                case .deepL:
                    try await keychain.save(key: .deepLAPIKey, value: deepLKey)
                    deepLSaveError = nil
                case .elevenLabs:
                    try await keychain.save(key: .elevenLabsAPIKey, value: elevenLabsKey)
                    elevenLabsSaveError = nil
                }
            } catch {
                let message = error.localizedDescription
                switch provider {
                case .deepL: deepLSaveError = message
                case .elevenLabs: elevenLabsSaveError = message
                }
            }
        }
    }

    private func loadStoredKeys() async {
        deepLKey = (try? await keychain.load(key: .deepLAPIKey)) ?? ""
        elevenLabsKey = (try? await keychain.load(key: .elevenLabsAPIKey)) ?? ""
    }

    private func testConnection(_ provider: Provider) async {
        switch provider {
        case .deepL:
            isTestingDeepL = true
            deepLTestResult = await tester.testDeepL(apiKey: deepLKey)
            isTestingDeepL = false
        case .elevenLabs:
            isTestingElevenLabs = true
            elevenLabsTestResult = await tester.testElevenLabs(apiKey: elevenLabsKey)
            isTestingElevenLabs = false
        }
    }
}
