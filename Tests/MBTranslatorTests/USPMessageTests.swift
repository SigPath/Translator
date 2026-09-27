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
}
