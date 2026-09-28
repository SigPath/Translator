import Foundation
import Testing
@testable import MBTranslator

@Suite("USPMessage")
struct USPMessageTests {
    @Test("Text message round-trips through encode/parse")
    func textRoundTrip() {
        let outgoing = USPOutgoingMessage.text(
            path: "speech.config",
            requestId: "abc123",
            contentType: "application/json",
            body: "{\"hello\":\"world\"}"
        )

        let parsed = USPIncomingMessage.parse(text: outgoing.encodeText())

        #expect(parsed.path == "speech.config")
        #expect(parsed.headers["x-requestid"] == "abc123")
        #expect(parsed.headers["content-type"] == "application/json")
        #expect(parsed.textBody == "{\"hello\":\"world\"}")
    }

    @Test("Binary message round-trips through encode/parse, including empty body")
    func binaryRoundTrip() {
        let body = Data([0x01, 0x02, 0x03, 0xff])
        let outgoing = USPOutgoingMessage.binary(path: "audio", requestId: "req-1", streamId: "1", body: body)

        let parsed = USPIncomingMessage.parse(binary: outgoing.encodeBinary())

        #expect(parsed?.path == "audio")
        #expect(parsed?.headers["x-streamid"] == "1")
        #expect(parsed?.binaryBody == body)
    }

    @Test("Binary message with nil body (end-of-stream marker) round-trips")
    func binaryNilBodyRoundTrip() {
        let outgoing = USPOutgoingMessage.binary(path: "audio", requestId: "req-2", streamId: "1", body: nil)

        let parsed = USPIncomingMessage.parse(binary: outgoing.encodeBinary())

        #expect(parsed?.path == "audio")
        #expect(parsed?.binaryBody == nil)
    }

    @Test("Header parsing is case-insensitive on lookup")
    func headerLookupIsCaseInsensitive() {
        let parsed = USPIncomingMessage.parse(text: "Path: turn.start\r\nX-RequestId: xyz\r\n\r\n{}")

        #expect(parsed.path == "turn.start")
        #expect(parsed.textBody == "{}")
    }

    @Test("Regression: real Azure turn.start message (no space after colon) parses correctly")
    func realAzureTurnStartMessageParses() {
        // Exact byte-for-byte shape of a real message received from Azure
        // Speech: this previously failed because Swift's `Character` treats
        // "\r\n" as a single extended grapheme cluster, so the old
        // per-character split (`{ $0 == "\r" || $0 == "\n" }`) never matched
        // it and swallowed every header past the first into one giant value.
        let raw = "X-RequestId:942a23dab25d4351bee25132443be2c1\r\n" +
            "Path:turn.start\r\n" +
            "Content-Type:application/json; charset=utf-8\r\n" +
            "\r\n" +
            "{\r\n  \"context\": {\r\n    \"serviceTag\": \"9a3a5f2a62df407d9813ceea846f81fc\"\r\n  }\r\n}"

        let parsed = USPIncomingMessage.parse(text: raw)

        #expect(parsed.path == "turn.start")
        #expect(parsed.headers["x-requestid"] == "942a23dab25d4351bee25132443be2c1")
        #expect(parsed.headers["content-type"] == "application/json; charset=utf-8")
        #expect(parsed.textBody?.contains("serviceTag") == true)
    }
}
