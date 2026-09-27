import SwiftUI

struct APIKeysSettingsTab: View {
    @State private var azureSpeechKey: String = ""
    @State private var azureSpeechRegion: String = ""
    @State private var elevenLabsKey: String = ""
    @State private var azureTestResult: ConnectionTestResult?
    @State private var elevenLabsTestResult: ConnectionTestResult?
    @State private var azureSaveError: String?
    @State private var elevenLabsSaveError: String?
    @State private var isTestingAzure = false
    @State private var isTestingElevenLabs = false

    private let keychain = KeychainStore.shared
    private let tester = APIConnectionTester()

    var body: some View {
        Form {
            Section("Azure AI Speech") {
                SecureField("Klucz API Azure Speech", text: $azureSpeechKey)
                TextField("Region", text: $azureSpeechRegion, prompt: Text("np. northeurope"))
                HStack {
                    Button("Zapisz") { save(.azureSpeech) }
                    Button("Testuj połączenie") { Task { await testConnection(.azureSpeech) } }
                        .disabled(azureSpeechKey.isEmpty || azureSpeechRegion.isEmpty || isTestingAzure)
                    statusView(isTesting: isTestingAzure, result: azureTestResult)
                }
                if let azureSaveError {
                    Text(azureSaveError).foregroundStyle(.red).font(.caption)
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
        case azureSpeech
        case elevenLabs
    }

    private func save(_ provider: Provider) {
        Task {
            do {
                switch provider {
                case .azureSpeech:
                    try await keychain.save(key: .azureSpeechKey, value: azureSpeechKey)
                    try await keychain.save(key: .azureSpeechRegion, value: azureSpeechRegion)
                    azureSaveError = nil
                case .elevenLabs:
                    try await keychain.save(key: .elevenLabsAPIKey, value: elevenLabsKey)
                    elevenLabsSaveError = nil
                }
            } catch {
                let message = error.localizedDescription
                switch provider {
                case .azureSpeech: azureSaveError = message
                case .elevenLabs: elevenLabsSaveError = message
                }
            }
        }
    }

    private func loadStoredKeys() async {
        azureSpeechKey = (try? await keychain.load(key: .azureSpeechKey)) ?? ""
        azureSpeechRegion = (try? await keychain.load(key: .azureSpeechRegion)) ?? ""
        elevenLabsKey = (try? await keychain.load(key: .elevenLabsAPIKey)) ?? ""
    }

    private func testConnection(_ provider: Provider) async {
        switch provider {
        case .azureSpeech:
            isTestingAzure = true
            azureTestResult = await tester.testAzureSpeech(apiKey: azureSpeechKey, region: azureSpeechRegion)
            isTestingAzure = false
        case .elevenLabs:
            isTestingElevenLabs = true
            elevenLabsTestResult = await tester.testElevenLabs(apiKey: elevenLabsKey)
            isTestingElevenLabs = false
        }
    }
}
