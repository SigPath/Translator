import Testing
@testable import MBTranslator

@Suite("KeychainStore")
struct KeychainStoreTests {
    // Uses an isolated service namespace so tests never touch the real
    // "pl.mbgroup.translator" entries a developer may have saved locally.
    private let store = KeychainStore(service: "pl.mbgroup.translator.tests")

    @Test("Round-trips a value through save, load and delete")
    func roundTrip() async throws {
        try await store.delete(key: .deepLAPIKey)

        try await store.save(key: .deepLAPIKey, value: "test-value-123")
        let loaded = try await store.load(key: .deepLAPIKey)
        #expect(loaded == "test-value-123")

        try await store.save(key: .deepLAPIKey, value: "test-value-456")
        let updated = try await store.load(key: .deepLAPIKey)
        #expect(updated == "test-value-456")

        try await store.delete(key: .deepLAPIKey)
        let afterDelete = try await store.load(key: .deepLAPIKey)
        #expect(afterDelete == nil)
    }

    @Test("Load returns nil for a key that was never saved")
    func missingKeyReturnsNil() async throws {
        try await store.delete(key: .elevenLabsAPIKey)
        let value = try await store.load(key: .elevenLabsAPIKey)
        #expect(value == nil)
    }
}
