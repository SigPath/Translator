import Foundation
import os

/// Real-time speech recognition + translation over Azure AI Speech's
/// WebSocket endpoint, implemented directly against the "USP" protocol
/// (see `USPMessage.swift`) rather than the official Speech SDK — the SDK
/// isn't available via Swift Package Manager (see docs/DECISIONS.md), so
/// pulling it in would mean CocoaPods or a hand-vendored `.xcframework`,
/// against the brief's "minimal SPM dependencies" goal.
///
/// Every wire-level detail here (endpoint, headers, message framing,
/// incoming JSON field names) was verified by reading Microsoft's own
/// open-source `cognitive-services-speech-sdk-js` — specifically
/// `TranslationConnectionFactory.ts` (endpoint/query params),
/// `CognitiveSubscriptionKeyAuthentication.ts` (auth header),
/// `ServiceRecognizerBase.ts` (message send sequence and WAV header),
/// `TranslationServiceRecognizer.ts` and `ServiceMessages/Translation*.ts`
/// (older `translation.hypothesis`/`translation.phrase` response schema,
/// kept for compatibility — see `handleLegacyTranslationMessage`). The
/// `universal/v2` endpoint we actually use sends results on a *different*
/// path, `translation.response`, confirmed on real traffic and cross-
/// checked against `TranslationServiceRecognizer.ts`'s own dispatch logic
/// for it (see `decodeTranslationResponse`). The outgoing `speech.context`
/// body's exact schema also turned out to differ from what the TypeScript
/// source alone implied — verified by directly capturing the real
/// byte-for-byte payload the official Python SDK's native core sends. See
/// docs/DECISIONS.md for the exact findings, sources, and how each was
/// verified — nothing here is guessed.
final class AzureSpeechTranslationService: SpeechTranslationService, Sendable {
    private let subscriptionKey: String
    private let region: String
    private let logger = Logger(subsystem: AppLogging.subsystem, category: "AzureSpeechTranslationService")

    /// Proactively reconnect this long before the documented ~1h session
    /// limit, so a slow reconnect never risks crossing it.
    private let sessionRenewalInterval: TimeInterval = 55 * 60
    private let maxConsecutiveFailures = 5

    init(subscriptionKey: String, region: String) {
        self.subscriptionKey = subscriptionKey
        self.region = region
    }

    func recognize(
        audioChunks: AsyncStream<Data>,
        sourceLanguage: String,
        targetLanguage: String
    ) -> AsyncThrowingStream<SpeechTranslationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runSession(
                        audioChunks: audioChunks,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Session (reconnect/backoff) loop

    private func runSession(
        audioChunks: AsyncStream<Data>,
        sourceLanguage: String,
        targetLanguage: String,
        continuation: AsyncThrowingStream<SpeechTranslationEvent, Error>.Continuation
    ) async throws {
        var iterator = audioChunks.makeAsyncIterator()
        var consecutiveFailures = 0

        while !Task.isCancelled {
            let deadline = Date().addingTimeInterval(sessionRenewalInterval)
            do {
                let sourceEnded = try await runSingleConnection(
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    chunkIterator: &iterator,
                    deadline: deadline,
                    continuation: continuation
                )
                consecutiveFailures = 0
                if sourceEnded {
                    print("[AzureSpeechTranslationService] runSession returning: audio source ended") // TEMP (M2a debug) — remove once confirmed working
                    return
                }
                // Deadline reached (planned renewal) — loop immediately, no backoff.
            } catch {
                consecutiveFailures += 1
                print("[AzureSpeechTranslationService] runSession attempt \(consecutiveFailures) failed: \(error)") // TEMP (M2a debug)
                logger.error("Azure Speech session attempt \(consecutiveFailures) failed: \(error.localizedDescription, privacy: .public)")
                if consecutiveFailures > maxConsecutiveFailures {
                    throw error
                }
                let backoffSeconds = min(30.0, pow(2.0, Double(consecutiveFailures)))
                try? await Task.sleep(for: .seconds(backoffSeconds))
            }
        }
    }

    // MARK: - Single WebSocket connection

    /// Returns `true` once `audioChunks` has ended (caller should stop for
    /// good); `false` when this connection ended for another reason (planned
    /// renewal at `deadline`) and the caller should open a new one.
    private func runSingleConnection(
        sourceLanguage: String,
        targetLanguage: String,
        chunkIterator: inout AsyncStream<Data>.AsyncIterator,
        deadline: Date,
        continuation: AsyncThrowingStream<SpeechTranslationEvent, Error>.Continuation
    ) async throws -> Bool {
        guard var components = URLComponents(string: "wss://\(region).stt.speech.microsoft.com/stt/speech/universal/v2") else {
            throw SpeechTranslationError.invalidRegion
        }
        components.queryItems = [
            URLQueryItem(name: "from", value: sourceLanguage),
            URLQueryItem(name: "to", value: targetLanguage),
            URLQueryItem(name: "scenario", value: "interactive"),
        ]
        guard let url = components.url else {
            throw SpeechTranslationError.invalidRegion
        }

        var request = URLRequest(url: url)
        let connectionId = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        request.setValue(subscriptionKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue(connectionId, forHTTPHeaderField: "X-ConnectionId")
        request.setValue(connectionId, forHTTPHeaderField: "connectionId")

        let session = URLSession(configuration: .default)
        let webSocketTask = session.webSocketTask(with: request)
        webSocketTask.resume()
        print("[AzureSpeechTranslationService] WebSocket resumed: \(url)") // TEMP (M2a debug) — remove once confirmed working

        let requestId = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")

        do {
            try await send(text: Self.speechConfigMessage(requestId: requestId), on: webSocketTask)
            try await send(text: Self.speechContextMessage(requestId: requestId, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage), on: webSocketTask)
            try await send(binary: Self.waveHeaderMessage(requestId: requestId), on: webSocketTask)
            print("[AzureSpeechTranslationService] sent speech.config/context + WAV header") // TEMP (M2a debug)
        } catch {
            print("[AzureSpeechTranslationService] failed sending initial messages: \(error)") // TEMP (M2a debug)
            webSocketTask.cancel(with: .abnormalClosure, reason: nil)
            throw SpeechTranslationError.connectionFailed(error.localizedDescription)
        }

        let receiveTask = Task {
            await self.receiveLoop(webSocketTask: webSocketTask, continuation: continuation)
        }

        var sourceEnded = false
        var vadTracker = VoiceActivityTracker(chunkDurationMs: 100)
        var sendError: Error?
        var endReason = "unknown"
        var chunkCount = 0 // TEMP (M2a debug): proves how many chunks actually reached the send loop before it ended.

        sendLoop: while !Task.isCancelled, Date() < deadline {
            print("[AzureSpeechTranslationService] send loop: awaiting chunkIterator.next() (received \(chunkCount) so far)") // TEMP (M2a debug)
            guard let chunk = await chunkIterator.next() else {
                sourceEnded = true
                endReason = "audio source ended after \(chunkCount) chunks"
                break sendLoop
            }
            chunkCount += 1
            // `vadTracker.isSpeechDetected` is still computed — its
            // calibrated threshold and verdict are useful diagnostics now,
            // and will drive a "listening/speaking" UI indicator in M2b —
            // but the result no longer decides whether to *transmit* this
            // chunk. Verified (docs/DECISIONS.md): Azure's own real-time
            // endpoint performs its own server-side VAD/end-of-utterance
            // detection on the continuous audio stream it receives; a
            // client that stops sending bytes during silence gives the
            // server nothing to detect "speech ended" from — it just keeps
            // waiting. That was why no `SpeechPhrase`/final result ever
            // arrived even after a deliberate silence pause: our own gate
            // was silently discarding exactly the silence Azure's
            // endpointer needed to see. Matches Microsoft's own description
            // of real-time speech input ("can contain not only voice, but
            // also silence... the system continuously determines the most
            // likely sequence of words that produced the audio observed so
            // far").
            let amplitude = VoiceActivityDetector.rms(chunk)
            let vadVerdict = vadTracker.isSpeechDetected(chunk) // side effect: may complete calibration
            let thresholdDescription = vadTracker.currentThreshold.map { String(format: "%.1f", $0) } ?? "calibrating"
            // TEMP (M2a debug): raw first-8-samples dump of the *exact same*
            // Data the RMS above was computed on (and that gets sent over
            // the WebSocket) — proves whether the PCM really is all-zero at
            // this point, rather than the RMS math itself being at fault.
            let firstSamples: [Int16] = chunk.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Int16.self).prefix(8))
            }
            print("[AzureSpeechTranslationService] chunk #\(chunkCount): \(chunk.count) bytes, amplitude=\(amplitude), threshold=\(thresholdDescription), vadVerdict=\(vadVerdict ? "voice" : "silence") (always sent — VAD no longer gates transmission), firstSamples=\(firstSamples)")
            do {
                try await send(binary: Self.audioMessage(requestId: requestId, body: chunk), on: webSocketTask)
                print("[AzureSpeechTranslationService] send loop: chunk #\(chunkCount) sent over WebSocket") // TEMP (M2a debug)
            } catch {
                sendError = error
                endReason = "send failed after \(chunkCount) chunks: \(error)"
                break sendLoop
            }
        }
        if endReason == "unknown" {
            endReason = Task.isCancelled ? "task cancelled" : "renewal deadline reached"
        }
        print("[AzureSpeechTranslationService] send loop ending: \(endReason)") // TEMP (M2a debug) — remove once confirmed working

        // Best-effort: signal end of this connection's audio, then tear down.
        try? await send(binary: Self.audioMessage(requestId: requestId, body: nil), on: webSocketTask)
        webSocketTask.cancel(with: .normalClosure, reason: nil)
        receiveTask.cancel()
        print("[AzureSpeechTranslationService] connection closed: closeCode=\(webSocketTask.closeCode.rawValue) closeReason=\(webSocketTask.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? "nil")") // TEMP (M2a debug)

        if let sendError {
            throw SpeechTranslationError.connectionFailed(sendError.localizedDescription)
        }

        return sourceEnded
    }

    private func receiveLoop(
        webSocketTask: URLSessionWebSocketTask,
        continuation: AsyncThrowingStream<SpeechTranslationEvent, Error>.Continuation
    ) async {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await webSocketTask.receive()
            } catch {
                print("[AzureSpeechTranslationService] receive() threw: \(error) — closeCode=\(webSocketTask.closeCode.rawValue) closeReason=\(webSocketTask.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? "nil")") // TEMP (M2a debug) — remove once confirmed working
                return
            }

            let incoming: USPIncomingMessage?
            switch message {
            case .string(let text):
                print("[AzureSpeechTranslationService] RAW text message:\n\(text)") // TEMP (M2a debug)
                incoming = USPIncomingMessage.parse(text: text)
            case .data(let data):
                incoming = USPIncomingMessage.parse(binary: data)
                print("[AzureSpeechTranslationService] RAW binary message: path=\(incoming?.path ?? "?") headers=\(incoming?.headers ?? [:]) bodyBytes=\(incoming?.binaryBody?.count ?? 0)") // TEMP (M2a debug)
            @unknown default:
                incoming = nil
                print("[AzureSpeechTranslationService] RAW message: unknown case") // TEMP (M2a debug)
            }

            guard let incoming, let path = incoming.path else {
                print("[AzureSpeechTranslationService] message had no Path header, ignoring") // TEMP (M2a debug)
                continue
            }
            handle(path: path, message: incoming, continuation: continuation)
        }
    }

    private func handle(
        path: String,
        message: USPIncomingMessage,
        continuation: AsyncThrowingStream<SpeechTranslationEvent, Error>.Continuation
    ) {
        switch path.lowercased() {
        case "translation.response":
            // The actual path the `universal/v2` endpoint uses for
            // translation results — confirmed on real traffic (see
            // docs/DECISIONS.md). Verified against the real JS SDK dispatch
            // in `TranslationServiceRecognizer.ts`: it JSON-decodes the body
            // once, checks for a `SpeechPhrase` key first (final result,
            // whose nested object carries its own `RecognitionStatus` per
            // `ITranslationPhrase`), and only if that's absent falls back to
            // `SpeechHypothesis` (partial result, no status field — always
            // provisional). `TranslationStatus`/`Translations` sit at the
            // top level either way, confirmed directly from a real captured
            // message.
            guard let body = message.textBody, let parsed = Self.decodeTranslationResponse(body) else {
                print("[AzureSpeechTranslationService] translation.response: could not decode body") // TEMP (M2a debug)
                return
            }
            let translatedText = parsed.Translations?.first?.Text ?? parsed.Translations?.first?.DisplayText
            if let phrase = parsed.SpeechPhrase {
                let status = phrase.RecognitionStatus ?? parsed.TranslationStatus
                guard status?.caseInsensitiveCompare("Success") == .orderedSame else {
                    print("[AzureSpeechTranslationService] translation.response (phrase) non-success status: \(status ?? "?")") // TEMP (M2a debug)
                    logger.info("translation.response (phrase) non-success status: \(status ?? "?", privacy: .public)")
                    return
                }
                if let text = phrase.Text {
                    continuation.yield(.sourceFinal(text))
                }
                if let translated = translatedText {
                    continuation.yield(.translationFinal(translated))
                }
            } else if let hypothesis = parsed.SpeechHypothesis {
                if let text = hypothesis.Text {
                    continuation.yield(.sourcePartial(text))
                }
                if let translated = translatedText {
                    continuation.yield(.translationPartial(translated))
                }
            } else {
                print("[AzureSpeechTranslationService] translation.response: neither SpeechPhrase nor SpeechHypothesis present") // TEMP (M2a debug)
            }

        case "translation.hypothesis", "translation.phrase":
            // Kept for the older (non-`universal/v2`) wire shape — see the
            // `translation.response` case above for what our current
            // endpoint actually sends. Harmless to leave handled in case a
            // future endpoint/reconnect path ever uses it.
            Self.handleLegacyTranslationMessage(path: path, message: message, logger: logger, continuation: continuation)

        case "speech.hypothesis", "speech.phrase":
            // Deliberately ignored, not unhandled: these are the plain
            // recognition "pass-through" results (source-language text
            // only) — emitted because `speech.context`'s `translation.
            // output.includePassThroughResults` is `true` (verified against
            // the JS SDK, see docs/DECISIONS.md). `translation.response`
            // above carries the *same* source text (its own `Text` field)
            // plus the EN translation in one message, so handling these too
            // would just emit duplicate `.sourcePartial`/`.sourceFinal`
            // events for every utterance.
            break

        case "error":
            print("[AzureSpeechTranslationService] received explicit \"error\" path message (see RAW log above for content)") // TEMP (M2a debug)
            logger.error("Received USP error message")

        default:
            print("[AzureSpeechTranslationService] ignoring path: \(path)") // TEMP (M2a debug)
            logger.debug("Ignoring USP message path: \(path, privacy: .public)")
        }
    }

    private func send(text message: USPOutgoingMessage, on task: URLSessionWebSocketTask) async throws {
        let encoded = message.encodeText()
        // TEMP (M2a debug): the exact bytes actually handed to the
        // WebSocket, not just what the building code is supposed to
        // produce — settles "what's really on the wire" definitively.
        print("[AzureSpeechTranslationService] >>> SENDING text message:\n\(encoded)")
        try await task.send(.string(encoded))
    }

    private func send(binary message: USPOutgoingMessage, on task: URLSessionWebSocketTask) async throws {
        try await task.send(.data(message.encodeBinary()))
    }

    // MARK: - Outgoing message builders

    /// The `"audio"` sub-object matches byte-for-byte what the *real*
    /// native SDK core sends (captured directly, see the doc comment on
    /// `speechContextMessage` below for how) — added for parity even though
    /// it's likely informational, since the audio format is already
    /// conveyed via the WAV header binary message.
    private static func speechConfigMessage(requestId: String) -> USPOutgoingMessage {
        let json = """
        {"context":{"system":{"name":"MBTranslator","version":"0.1.0","build":"Swift","lang":"Swift"},"os":{"platform":"macOS","name":"macOS","version":"14.0"},"audio":{"source":{"type":"Stream","model":"","samplerate":"16000","bitspersample":"16","channelcount":"1"}}}}
        """
        return .text(path: "speech.config", requestId: requestId, contentType: "application/json", body: json)
    }

    /// The previous `translation.onSuccess`/`onPassthrough` structure (built
    /// from reading the JS SDK's TypeScript source via an LLM-summarizing
    /// fetch tool) was simply **wrong** for this endpoint/protocol version —
    /// confirmed by capturing the *actual* bytes the official Python SDK
    /// sends (same native "Carbon" core as every other official SDK
    /// binding): installed `azure-cognitiveservices-speech` locally, fed it
    /// synthetic PCM via a `PushAudioInputStream` (no real mic/key needed —
    /// a placeholder subscription key still exercises the SDK's own
    /// USP-message construction before the server rejects the connection on
    /// auth), and enabled its native protocol debug log via
    /// `PropertyId.Speech_LogFilename`. The log's `usp_reco_engine_adapter.
    /// cpp:1329` line is the literal `speech.context` the SDK builds:
    /// `{"phraseDetection":{"mode":"INTERACTIVE","language":"pl-PL",
    /// "onSuccess":{"action":"Translate"},"onInterim":{"action":"Translate"}},
    /// "translation":{"targetLanguages":["en"],"output":
    /// {"includePassThroughResults":true}},"audio":{"streams":{"1":null}}}`.
    /// The actual trigger for translation mode is `phraseDetection.
    /// onSuccess`/`onInterim` (`action: "Translate"`) — not anything under
    /// `translation` itself, which only carries `targetLanguages`/`output`.
    /// See docs/DECISIONS.md for the full capture and how it was obtained.
    private static func speechContextMessage(requestId: String, sourceLanguage: String, targetLanguage: String) -> USPOutgoingMessage {
        let json = """
        {"phraseDetection":{"mode":"INTERACTIVE","language":"\(sourceLanguage)","onSuccess":{"action":"Translate"},"onInterim":{"action":"Translate"}},"translation":{"targetLanguages":["\(targetLanguage)"],"output":{"includePassThroughResults":true}},"audio":{"streams":{"1":null}}}
        """
        return .text(path: "speech.context", requestId: requestId, contentType: "application/json", body: json)
    }

    private static func waveHeaderMessage(requestId: String) -> USPOutgoingMessage {
        .binary(path: "audio", requestId: requestId, contentType: "audio/x-wav", streamId: "1", body: makeStreamingWavHeader())
    }

    private static func audioMessage(requestId: String, body: Data?) -> USPOutgoingMessage {
        .binary(path: "audio", requestId: requestId, streamId: "1", body: body)
    }

    /// 44-byte streaming WAV header for PCM16 mono 16 kHz, with RIFF/data
    /// sizes left at 0 (the service reads audio as a continuous stream, not
    /// a bounded file) — byte-for-byte matching the layout the JS SDK builds
    /// in `AudioStreamFormat.ts`.
    private static func makeStreamingWavHeader() -> Data {
        var header = Data(count: 44)
        header.replaceSubrange(0..<4, with: Data("RIFF".utf8))
        header.replaceSubrange(8..<16, with: Data("WAVEfmt ".utf8))
        header.replaceSubrange(36..<40, with: Data("data".utf8))

        func setUInt32(_ value: UInt32, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { header.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        func setUInt16(_ value: UInt16, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { header.replaceSubrange(offset..<(offset + 2), with: $0) }
        }

        setUInt32(0, at: 4) // RIFF chunk size (unknown/streaming)
        setUInt32(16, at: 16) // fmt chunk size
        setUInt16(1, at: 20) // format tag: PCM
        setUInt16(1, at: 22) // channels
        setUInt32(16000, at: 24) // sample rate
        setUInt32(32000, at: 28) // byte rate = 16000 * 1 channel * 2 bytes
        setUInt16(2, at: 32) // block align
        setUInt16(16, at: 34) // bits per sample
        setUInt32(0, at: 40) // data chunk size (unknown/streaming)

        return header
    }

    // MARK: - Incoming JSON

    private struct DecodedTranslationBody {
        let recognitionStatus: String?
        let text: String?
        let translatedText: String?
    }

    private static func decodeTranslationBody(_ json: String) -> DecodedTranslationBody? {
        struct TranslationEntry: Decodable { let Language: String; let Text: String? }
        struct Translation: Decodable { let Translations: [TranslationEntry]? }
        struct Body: Decodable {
            let RecognitionStatus: String?
            let Text: String?
            let DisplayText: String?
            let Translation: Translation?
        }

        guard let data = json.data(using: .utf8),
              let body = try? JSONDecoder().decode(Body.self, from: data)
        else {
            return nil
        }

        return DecodedTranslationBody(
            recognitionStatus: body.RecognitionStatus,
            text: body.Text ?? body.DisplayText,
            translatedText: body.Translation?.Translations?.first?.Text
        )
    }

    private static func handleLegacyTranslationMessage(
        path: String,
        message: USPIncomingMessage,
        logger: Logger,
        continuation: AsyncThrowingStream<SpeechTranslationEvent, Error>.Continuation
    ) {
        guard let body = message.textBody, let parsed = Self.decodeTranslationBody(body) else {
            print("[AzureSpeechTranslationService] \(path): could not decode body") // TEMP (M2a debug)
            return
        }
        if path.caseInsensitiveCompare("translation.phrase") == .orderedSame {
            guard parsed.recognitionStatus?.caseInsensitiveCompare("Success") == .orderedSame else {
                print("[AzureSpeechTranslationService] translation.phrase non-success status: \(parsed.recognitionStatus ?? "?")") // TEMP (M2a debug)
                logger.info("translation.phrase non-success status: \(parsed.recognitionStatus ?? "?", privacy: .public)")
                return
            }
            if let text = parsed.text {
                continuation.yield(.sourceFinal(text))
            }
            if let translated = parsed.translatedText {
                continuation.yield(.translationFinal(translated))
            }
        } else {
            if let text = parsed.text {
                continuation.yield(.sourcePartial(text))
            }
            if let translated = parsed.translatedText {
                continuation.yield(.translationPartial(translated))
            }
        }
    }

    // MARK: - Incoming JSON: translation.response (the path our endpoint actually uses)

    private struct TranslationResponseSpeechResult: Decodable {
        let Text: String?
        let RecognitionStatus: String?
    }

    private struct TranslationResponseEntry: Decodable {
        let Language: String
        let Text: String?
        let DisplayText: String?
    }

    /// Field names match a real captured `translation.response` message
    /// byte-for-byte (see docs/DECISIONS.md) — `SpeechHypothesis`/
    /// `SpeechPhrase` are mutually exclusive per message, `TranslationStatus`
    /// and `Translations` sit at the top level regardless of which one is
    /// present.
    private struct TranslationResponseBody: Decodable {
        let SpeechHypothesis: TranslationResponseSpeechResult?
        let SpeechPhrase: TranslationResponseSpeechResult?
        let TranslationStatus: String?
        let Translations: [TranslationResponseEntry]?
    }

    private static func decodeTranslationResponse(_ json: String) -> TranslationResponseBody? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TranslationResponseBody.self, from: data)
    }
}
