import Foundation

/// Encodes/decodes the "USP" (Universal Speech Protocol) framing Azure
/// Speech's real-time WebSocket endpoint uses. This is not publicly
/// documented for third-party use the way DeepL's Voice API is — verified
/// instead by reading Microsoft's own open-source JS SDK
/// (github.com/microsoft/cognitive-services-speech-sdk-js), specifically
/// `src/common.speech/WebsocketMessageFormatter.ts` and
/// `SpeechConnectionMessage.Internal.ts`, not guessed. See docs/DECISIONS.md.
///
/// Text message wire format: `"{Header: value\r\n...}\r\n\r\n{body}"`.
/// Binary message wire format: `[2-byte big-endian header length]{headers}{body}`,
/// where `{headers}` uses the same `"Header: value\r\n"` lines (no blank-line
/// separator needed since the length prefix delimits them).
struct USPOutgoingMessage {
    let headers: [(name: String, value: String)]
    let textBody: String?
    let binaryBody: Data?

    static func text(path: String, requestId: String, contentType: String? = nil, body: String) -> USPOutgoingMessage {
        USPOutgoingMessage(headers: commonHeaders(path: path, requestId: requestId, contentType: contentType), textBody: body, binaryBody: nil)
    }

    static func binary(
        path: String,
        requestId: String,
        contentType: String? = nil,
        streamId: String? = nil,
        body: Data?
    ) -> USPOutgoingMessage {
        var headers = commonHeaders(path: path, requestId: requestId, contentType: contentType)
        if let streamId {
            headers.append(("X-StreamId", streamId))
        }
        return USPOutgoingMessage(headers: headers, textBody: nil, binaryBody: body)
    }

    private static func commonHeaders(path: String, requestId: String, contentType: String?) -> [(name: String, value: String)] {
        var headers: [(name: String, value: String)] = [
            ("Path", path),
            ("X-RequestId", requestId),
            ("X-Timestamp", ISO8601DateFormatter().string(from: Date())),
        ]
        if let contentType {
            headers.append(("Content-Type", contentType))
        }
        return headers
    }

    private var headerLines: String {
        headers.map { "\($0.name): \($0.value)" }.joined(separator: "\r\n")
    }

    func encodeText() -> String {
        "\(headerLines)\r\n\r\n\(textBody ?? "")"
    }

    func encodeBinary() -> Data {
        let headerData = Data((headerLines + "\r\n").utf8)
        let headerLength = UInt16(headerData.count)
        var payload = Data(capacity: 2 + headerData.count + (binaryBody?.count ?? 0))
        payload.append(UInt8(headerLength >> 8))
        payload.append(UInt8(headerLength & 0xff))
        payload.append(headerData)
        if let binaryBody {
            payload.append(binaryBody)
        }
        return payload
    }
}

struct USPIncomingMessage {
    /// Lowercased header names, for case-insensitive lookup.
    let headers: [String: String]
    let textBody: String?
    let binaryBody: Data?

    var path: String? { headers["path"] }

    static func parse(text: String) -> USPIncomingMessage {
        guard let separatorRange = text.range(of: "\r\n\r\n") else {
            return USPIncomingMessage(headers: parseHeaders(text), textBody: nil, binaryBody: nil)
        }
        let headerPart = String(text[text.startIndex..<separatorRange.lowerBound])
        let bodyPart = String(text[separatorRange.upperBound...])
        return USPIncomingMessage(headers: parseHeaders(headerPart), textBody: bodyPart, binaryBody: nil)
    }

    static func parse(binary data: Data) -> USPIncomingMessage? {
        guard data.count >= 2 else { return nil }
        let base = data.startIndex
        let headerLength = Int(data[base]) << 8 | Int(data[base + 1])
        let headerStart = base + 2
        guard data.endIndex - headerStart >= headerLength else { return nil }
        let headerEnd = headerStart + headerLength
        let headerString = String(decoding: data[headerStart..<headerEnd], as: UTF8.self)
        let bodyData = headerEnd < data.endIndex ? data[headerEnd..<data.endIndex] : nil
        return USPIncomingMessage(headers: parseHeaders(headerString), textBody: nil, binaryBody: bodyData.map { Data($0) })
    }

    private static func parseHeaders(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in raw.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }
}
