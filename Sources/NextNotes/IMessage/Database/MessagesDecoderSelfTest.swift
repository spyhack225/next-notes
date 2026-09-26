import Foundation

/// `--selftest-imessage-decode` — NextNotes-iMessage IM-05.
///
/// The `attributedBody` decoder, its refusal, and the shape of the value a refusal produces.
/// **No Full Disk Access, no iPhone, no grant and no real blob**: every case runs against the
/// sanitised corpus in `Tests/Fixtures/chatdb/` and against streams this process asks Apple's
/// own encoder to write.
///
/// **The corpus holds no real typedstream, and this test does not pretend otherwise.** Five of
/// the roadmap's six assertions cannot be built from placeholders, and each one is reported as
/// a named `IMESSAGE_DECODE_BLOCKED:` line and **is not counted** in the `IMESSAGE_DECODE_OK`
/// case total. That is the difference between an honest count and a flattering one: a number
/// that includes a case nobody ran is a claim about this test rather than about the decoder.
///
/// ## What the oracle can and cannot prove
///
/// `TYPEDSTREAM-NOTES.md` §2.3 sanctions one deliberate exception, and this is it: `NSArchiver`
/// is deprecated but still working, which makes it an **oracle**. Ask it to archive a string
/// whose contents this process already knows, and the bytes that come out can only mean one
/// thing. That pins the mechanics — the header, the shared-string table, the byte-counted
/// length, the `0x81` escape, the class chain, the descriptor grammar, and the refusal of
/// everything else.
///
/// **It does not prove the layout Messages writes**, which is a different question and the one
/// IM-01 exists to answer. `archiver_oracle_attributed_string` archives an
/// `NSMutableAttributedString`, which is the shape `TYPEDSTREAM-NOTES.md` §1.4 says a message
/// body has — so it is evidence for the shape, not a measurement of it, and the case names say
/// so. The blocked lines below are where that difference is recorded.
///
/// ## The load-bearing assertion
///
/// `version_mismatch_is_not_empty` and its four sibling refusals all assert the same thing from
/// different directions: **a body this Mac could not read comes back as `nil` text and a state
/// that says why, and never as `""`.** An empty string is a lie a person cannot tell from
/// silence; that is why `IMessageEnvelope.text` is a `switch` over a `MessageBody` with no
/// empty-string case rather than a stored field somebody can forget to set. `text_is_nil_or_non_empty`
/// then walks every row of every fixture and asserts the invariant over all of them at once.
///
/// The final line is `IMESSAGE_DECODE_OK: <n> cases` or `IMESSAGE_DECODE_FAILED: <case>:
/// <reason>`. The per-case diagnostic lines are `IMESSAGE_DECODE_WRONG: …`, which is not a
/// verdict token, and neither is `IMESSAGE_DECODE_BLOCKED: …`.
@MainActor
enum MessagesDecoderSelfTest {
    /// The fixture sentence the oracle cases archive, chosen the way `TYPEDSTREAM-NOTES.md` §3.2
    /// says to choose one: a body that is itself a placeholder, so it needs no sanitisation and
    /// cannot be a real conversation.
    static let oracleSentence = "FIXTURE-SENTENCE alpha bravo charlie"

    /// Longer than 127 bytes, so its length is written in the two-byte escape form. The case that
    /// catches a reader which reads one byte of a length and returns a truncated sentence with no
    /// error at all — the exact failure the roadmap's "do not string-search" rule is about.
    static let oracleLongSentence = String(repeating: "FIXTURE-", count: 60)

    /// One non-ASCII character is the cheapest capture there is for the bytes-versus-characters
    /// question: the payload is 14 UTF-8 bytes and 10 characters, so a reader that counted
    /// characters returns a mangled prefix.
    static let oracleNonASCII = "héllo 🌍 café — naïve"

    static func run() async -> String {
        var failures: [String] = []
        var blocked: [String] = []
        var caseCount = 0

        func check(_ name: String, _ body: () async throws -> String?) async rethrows {
            caseCount += 1
            do {
                if let problem = try await body() { failures.append("\(name): \(problem)") }
            } catch {
                failures.append("\(name): threw \(error)")
            }
        }

        /// A case that cannot be built yet, named and left out of the count. Never a silent skip.
        func block(_ name: String, _ waits: String) {
            blocked.append("\(name) — \(waits)")
        }

        do {
            let corpus = try DecoderFixtureCorpus.build()
            defer { corpus.discard() }

            // 1. A row with no `attributedBody` at all. This is `.absent`, not an error, and the
            // distinction is the whole reason `.absent` exists: an SMS is an ordinary message,
            // and a decoder that reports it as unreadable would be crying wolf on half the
            // history.
            var basic: MessagesDatabase?
            do { basic = try MessagesDatabase(root: corpus.url("basic-text")) } catch {
                failures.append("absent_without_attributed_body: the fixture did not open — \(error)")
            }

            if let basic {
                try await check("absent_without_attributed_body") {
                    let rows = try await basic.messages(after: 0, chatGUID: DecoderFixtureCorpus.directChatGUID)
                    guard rows.count == 2 else { return "expected 2 rows, got \(rows.count)" }
                    let row = rows[1]
                    guard row.text == nil, row.attributedBody == nil else {
                        return "row 2 was supposed to have neither text nor a body"
                    }
                    let envelope = MessagesDecoder.envelope(for: row)
                    if let text = envelope.text {
                        return "a row with no body column decoded to \"\(text)\""
                    }
                    guard envelope.decodeState == .absent else {
                        return "decodeState is \(envelope.decodeState), not .absent"
                    }
                    guard envelope.source == .noColumn else {
                        return "source is \(envelope.source), not .noColumn"
                    }
                    return nil
                }

                // 2. The same database, degraded: `message.attributedBody` genuinely does not
                // exist. The row has to degrade to `.absent` rather than fail, because a macOS
                // without the column is a database this app still has to read.
                try await check("degraded_database_is_absent_not_failure") {
                    let degraded = try MessagesDatabase(root: corpus.url("basic-text-degraded"))
                    let rows = try await degraded.messages(after: 0, chatGUID: DecoderFixtureCorpus.directChatGUID)
                    guard rows.count == 2 else { return "expected 2 rows, got \(rows.count)" }
                    guard degraded.capabilities.hasAttributedBody == false else {
                        return "the degraded fixture still has an attributedBody column"
                    }
                    let envelope = MessagesDecoder.envelope(for: rows[1])
                    guard envelope.text == nil, envelope.decodeState == .absent else {
                        return "a row on a database with no body column came back \(envelope.decodeState)"
                    }
                    return nil
                }
            }

            // 3. The developer's own test: an SMS, `text` populated, `attributedBody` genuinely
            // NULL. A decoder that reads only `text` passes this and fails every real message,
            // which is why it is a case rather than a footnote.
            try await check("sms_reads_the_text_column") {
                let sms = try MessagesDatabase(root: corpus.url("sms"))
                let rows = try await sms.messages(after: 0, chatGUID: DecoderFixtureCorpus.smsChatGUID)
                guard rows.count == 1 else { return "expected 1 row, got \(rows.count)" }
                guard rows[0].attributedBody == nil, rows[0].text == "FIXTURE-SMS-BODY-1" else {
                    return "the SMS row is not in the shape the case is about"
                }
                let envelope = MessagesDecoder.envelope(for: rows[0])
                guard envelope.text == "FIXTURE-SMS-BODY-1" else {
                    return "text is \(envelope.text ?? "nil"), expected the column's value"
                }
                guard envelope.decodeState == .decoded, envelope.source == .textColumn else {
                    return "state \(envelope.decodeState) from \(envelope.source)"
                }
                return nil
            }

            // 4. The refusal, and the "not an empty string" assertion, which is the roadmap's
            // Done-when for this task. `X'0001'` is two bytes whose leading byte is a streamer
            // version this decoder does not support — the shape `empty-attributed-body` was
            // built for.
            try await check("version_mismatch_is_not_empty") {
                let database = try MessagesDatabase(root: corpus.url("empty-attributed-body"))
                let rows = try await database.messages(after: 0, chatGUID: DecoderFixtureCorpus.directChatGUID)
                guard rows.count == 1, let blob = rows[0].attributedBody else {
                    return "the refusal fixture did not come back with one row carrying a body"
                }
                guard blob != Data() else { return "the sentinel is empty, so nothing was refused" }
                let envelope = MessagesDecoder.envelope(for: rows[0])
                // The assertion itself, in the two forms it can fail in.
                if envelope.text == "" { return "a body this Mac could not read came back as \"\"" }
                guard envelope.text == nil else { return "text is \"\(envelope.text!)\", not nil" }
                guard case .unreadable(let reason) = envelope.body else {
                    return "body is \(envelope.body), not .unreadable"
                }
                guard case .unsupportedStreamVersion(let found, let system) = reason else {
                    return "the refusal is \(reason), not a version refusal"
                }
                guard found == 0x00 else { return "the refusal names streamer 0x\(String(found, radix: 16))" }
                guard system == nil else { return "the refusal claims system \(system!) from a two-byte blob" }
                guard envelope.source == .attributedBody else { return "source is \(envelope.source)" }
                return nil
            }

            // 5/6. `both-paths`: one sentence, one chat, one column each. The **negative** half
            // runs today and the positive half is blocked — see the `IMESSAGE_DECODE_BLOCKED`
            // line. The structural half is what makes the positive half meaningful later: a
            // test that compared two rows differing in eight columns would be comparing two
            // different messages.
            do {
                let both = try MessagesDatabase(root: corpus.url("both-paths"))
                try await check("both_paths_differ_only_in_the_body") {
                    let rows = try await both.messages(after: 0, chatGUID: DecoderFixtureCorpus.directChatGUID)
                    guard rows.count == 2 else { return "expected 2 rows, got \(rows.count)" }
                    guard rows[0].text != nil, rows[0].attributedBody == nil else {
                        return "row A is supposed to carry the text and no body"
                    }
                    guard rows[1].text == nil, rows[1].attributedBody != nil else {
                        return "row B is supposed to carry a body and no text"
                    }
                    guard DecoderFixtureCorpus.withoutIdentityAndBody(rows[0])
                        == DecoderFixtureCorpus.withoutIdentityAndBody(rows[1]) else {
                        return "the two rows differ in a column other than the five that carry the body"
                    }
                    return nil
                }

                try await check("both_paths_row_b_refuses") {
                    let rows = try await both.messages(after: 0, chatGUID: DecoderFixtureCorpus.directChatGUID)
                    let envelope = MessagesDecoder.envelope(for: rows[1])
                    if envelope.text == "" { return "row B came back as \"\"" }
                    guard envelope.text == nil else { return "row B came back as \"\(envelope.text!)\"" }
                    guard case .unreadable = envelope.body else {
                        return "row B's body is \(envelope.body), not .unreadable"
                    }
                    guard envelope.decodeState != .decoded else { return "row B claims .decoded" }
                    return nil
                }
            } catch {
                failures.append("both_paths: the fixture did not open — \(error)")
            }

            // 7. A tapback: `payload_data` + `balloon_bundle_id`, and a `text` on the row it
            // reacts to. The reaction is a message that is not a message, and `.notText` is the
            // state the agent layer can say out loud.
            try await check("tapback_is_not_text") {
                let database = try MessagesDatabase(root: corpus.url("reaction"))
                let rows = try await database.messages(after: 0, chatGUID: DecoderFixtureCorpus.directChatGUID)
                guard rows.count == 2 else { return "expected 2 rows, got \(rows.count)" }
                let tapback = rows[1]
                guard tapback.payloadData != nil, tapback.text == nil,
                      let bundleID = tapback.balloonBundleID, !bundleID.isEmpty else {
                    return "row 2 is not the payload_data + balloon_bundle_id row this case is about"
                }
                let envelope = MessagesDecoder.envelope(for: tapback)
                guard envelope.text == nil else { return "a tapback came back as \"\(envelope.text!)\"" }
                guard case .notText(let reported) = envelope.body, reported == bundleID else {
                    return "body is \(envelope.body), not .notText(\(bundleID))"
                }
                guard envelope.decodeState == .notText(bundleID: bundleID) else {
                    return "decodeState is \(envelope.decodeState)"
                }
                guard envelope.source == .payloadData else { return "source is \(envelope.source)" }
                // And the row it reacts to is ordinary text, so the classification is the
                // balloon's and not the fixture's.
                guard MessagesDecoder.envelope(for: rows[0]).text == "FIXTURE-REACTEE-BODY" else {
                    return "the row the tapback answers did not decode as text"
                }
                return nil
            }

            // 8. A retracted row: `text` NULL, `is_retracted` 1, and the sentinel blob. Both
            // states it could decode into — an empty body and a refusal — are reachable from
            // the row, and the refusal is the one this decoder must reach. Whether a retraction
            // should reach it at all is IM-08's question, not this task's.
            try await check("retracted_row_refuses_rather_than_answering_empty") {
                let database = try MessagesDatabase(root: corpus.url("unsend"))
                let rows = try await database.messages(after: 0, chatGUID: DecoderFixtureCorpus.selfChatGUID)
                guard rows.count == 2 else { return "expected 2 rows, got \(rows.count)" }
                guard rows[0].isRetracted == true, rows[0].text == nil else {
                    return "row 1 is not the retracted row this case is about"
                }
                let envelope = MessagesDecoder.envelope(for: rows[0])
                if envelope.text == "" { return "a retracted row came back as \"\"" }
                guard envelope.text == nil, case .unreadable = envelope.body else {
                    return "a retracted row came back \(envelope.body)"
                }
                return nil
            }

            // 9. The invariant, over every row of every fixture at once rather than case by
            // case: `text` is nil or non-empty. A decoder that answers `""` anywhere fails here.
            try await check("text_is_nil_or_non_empty") {
                var read = 0
                for (fixture, chat) in corpus.cases.map({ ($0.name, $0.chatGUID) }) {
                    let database = try MessagesDatabase(root: corpus.url(fixture))
                    let rows = try await database.messages(after: 0, chatGUID: chat)
                    for row in rows {
                        read += 1
                        let envelope = MessagesDecoder.envelope(for: row)
                        if envelope.text == "" {
                            return "\(fixture) row \(row.rowID) decoded to the empty string"
                        }
                        if let text = envelope.text, text.isEmpty {
                            return "\(fixture) row \(row.rowID) decoded to the empty string"
                        }
                        if envelope.decodeState == .decoded, envelope.text == nil {
                            return "\(fixture) row \(row.rowID) claims .decoded with no text"
                        }
                    }
                }
                return read > 0 ? nil : "no rows were read at all, so nothing was checked"
            }

            // 10. The voice note. The corpus README says this row is IM-05's `.notText` case,
            // and it cannot be: nothing in IM-04's `MessageRow` distinguishes an audio message
            // from a text message whose body happens to be unreadable, and the honest answer
            // from this row today is the refusal. Reported as blocked rather than papered over.
            try await check("voice_note_is_classified_not_decoded") {
                let database = try MessagesDatabase(root: corpus.url("voice-note"))
                let rows = try await database.messages(after: 0, chatGUID: DecoderFixtureCorpus.directChatGUID)
                guard rows.count == 1 else { return "expected 1 row, got \(rows.count)" }
                guard rows[0].cacheHasAttachments == true else {
                    return "row 1 does not say it has an attachment"
                }
                let envelope = MessagesDecoder.envelope(for: rows[0])
                if envelope.text == "" { return "a voice note came back as \"\"" }
                guard envelope.text == nil else { return "a voice note came back as \"\(envelope.text!)\"" }
                guard case .unreadable = envelope.body else {
                    return "a voice note came back \(envelope.body)"
                }
                return nil
            }
            block("voice-note-as-not-text",
                  "the corpus README's `.notText` for `voice-note` needs a signal this row does not "
                  + "carry: IM-04's `MessageRow` does not project `is_audio_message`, and its "
                  + "`attributedBody` is the `X'0001'` sentinel. Needs a projected column in "
                  + "`MessagesQueries` (a file this task may not edit) — the row is classified as a "
                  + "refusal today, which is honest and not what the README says")
        } catch {
            failures.append("fixtures: \(error)")
        }

        // MARK: The oracle

        // 11. The header, measured rather than assumed. This is the case that goes red the day
        // a macOS changes what the encoder writes, which is the day the canary metric is for.
        await check("archiver_oracle_measured_header") {
            guard let blob = DecoderArchiverOracle.archive(oracleSentence as NSString) else {
                return "NSArchiver wrote nothing"
            }
            let body = MessagesDecoder.body(fromAttributedBody: blob)
            guard case .text = body else { return "the oracle's own stream was refused: \(body)" }
            let header = blob.prefix(13)
            guard header[header.startIndex] == 0x04 else {
                return "the streamer version is 0x\(String(header[header.startIndex], radix: 16))"
            }
            let measured = MessagesSchemaVersion(streamerVersion: 0x04, systemVersion: 1000)
            guard MessagesSchemaVersion.supported.contains(measured) else {
                return "the measured header is not in the supported set"
            }
            return nil
        }

        // 12/13. The shape a message body has, as far as it can be checked without a real blob:
        // an `NSAttributedString` whose first field is a nested `NSMutableString`.
        await check("archiver_oracle_attributed_string_decodes") {
            let expected = oracleSentence
            guard let blob = DecoderArchiverOracle.archive(
                NSMutableAttributedString(string: expected)) else {
                return "NSArchiver wrote nothing"
            }
            return Self.expect(blob, toDecodeTo: expected, caseName: "an NSMutableAttributedString")
        }

        await check("archiver_oracle_plain_string_decodes") {
            guard let blob = DecoderArchiverOracle.archive(oracleSentence as NSString) else {
                return "NSArchiver wrote nothing"
            }
            return Self.expect(blob, toDecodeTo: oracleSentence, caseName: "an NSString")
        }

        // 14. Bytes, not characters. The sentence is 10 characters and 14 UTF-8 bytes, so a
        // reader that counted characters returns 10 bytes of it and no error.
        await check("archiver_oracle_length_counts_bytes") {
            let expected = oracleNonASCII
            guard let blob = DecoderArchiverOracle.archive(expected as NSString) else {
                return "NSArchiver wrote nothing"
            }
            let bytes = Array(expected.utf8).count
            if bytes == expected.count {
                return "the fixture sentence is ASCII, so the case proves nothing — use a "
                    + "sentence with a non-ASCII character in it"
            }
            return Self.expect(blob, toDecodeTo: expected, caseName: "a non-ASCII NSString")
        }

        // 15. The two-byte length escape. `oracleLongSentence` is 540 bytes, well past the
        // 127 a single byte can hold, so its length is written `0x81` + `u16`.
        await check("archiver_oracle_long_string_is_not_truncated") {
            let expected = oracleLongSentence
            guard let blob = DecoderArchiverOracle.archive(expected as NSString) else {
                return "NSArchiver wrote nothing"
            }
            guard blob.count > expected.utf8.count else {
                return "the oracle's stream is shorter than its own payload"
            }
            return Self.expect(blob, toDecodeTo: expected, caseName: "a 540-byte NSString")
        }

        // 16. The attachment marker stays in. Stripping `U+FFFC` is how a photo message is made
        // to look empty, which is the failure this whole task exists to prevent.
        await check("archiver_oracle_attachment_marker_survives") {
            let expected = "\u{FFFC} a caption"
            guard let blob = DecoderArchiverOracle.archive(
                NSMutableAttributedString(string: expected)) else {
                return "NSArchiver wrote nothing"
            }
            return Self.expect(blob, toDecodeTo: expected, caseName: "a body with U+FFFC in it")
        }

        // 17. A character pointer is not a body. `NSNumber`'s first field is its `objCType`,
        // a `char *`, and a reader that took the first C string it saw would answer `q`.
        await check("archiver_oracle_character_pointer_is_refused") {
            guard let blob = DecoderArchiverOracle.archive(NSNumber(value: 42)) else {
                return "NSArchiver wrote nothing"
            }
            let body = MessagesDecoder.body(fromAttributedBody: blob)
            if case .text(let text) = body { return "an NSNumber came back as \"\(text)\"" }
            guard case .unreadable(let reason) = body else { return "body is \(body)" }
            guard case .notAString = reason else { return "the refusal is \(reason)" }
            return nil
        }

        // 18. Truncation coverage with no fuzzer. **Not** the assertion
        // `TYPEDSTREAM-NOTES.md` §4.1 states — that every proper prefix must be refused, which
        // is not true of a real blob and would be a test that has to be weakened: the message
        // text sits early in the stream, so a prefix that still contains the whole sentence
        // contains a body this Mac *can* read, and refusing it would be refusing real text. The
        // property that matters, and the one this asserts, is that no prefix ever decodes to
        // something *different* from the whole sentence: a truncated stream never yields a
        // shortened message with no error, which is the failure the notes are reaching for.
        await check("a_truncated_stream_never_decodes_to_a_different_string") {
            let expected = "FIXTURE-SENTENCE one two three"
            guard let blob = DecoderArchiverOracle.archive(
                NSMutableAttributedString(string: expected)) else {
                return "NSArchiver wrote nothing"
            }
            var read = 0
            var refused = 0
            for count in 0..<blob.count {
                read += 1
                let prefix = Data(blob.prefix(count))
                switch MessagesDecoder.body(fromAttributedBody: prefix) {
                case .text(let text):
                    guard text == expected else {
                        return "the first \(count) of \(blob.count) bytes decoded to \"\(text)\""
                    }
                case .unreadable:
                    refused += 1
                case .notText, .absent:
                    return "the first \(count) of \(blob.count) bytes came back as a non-body"
                }
            }
            guard read > 0, refused > 0 else {
                return "of \(read) prefixes, \(refused) were refused — one of the two must be"
            }
            return nil
        }

        // 19. A declared length that runs past the end. The classic out-of-bounds and the most
        // likely defect in a hand-written parser.
        await check("a_declared_length_past_the_end_is_refused") {
            let expected = "FIXTURE-SENTENCE one two three"
            guard let blob = DecoderArchiverOracle.archive(expected as NSString),
                  let stretched = DecoderFixtureCorpus.stretchDeclaredLength(in: blob) else {
                return "the oracle's stream did not have a length byte to stretch"
            }
            let body = MessagesDecoder.body(fromAttributedBody: stretched)
            if case .text(let text) = body { return "an over-long length decoded to \"\(text)\"" }
            guard case .unreadable(let reason) = body else { return "body is \(body)" }
            guard case .truncated = reason else { return "the refusal is \(reason), not a truncation" }
            return nil
        }

        // 20. The version gate, both halves. A good streamer version with the wrong system
        // version is refused, which is what makes the gate a *pair* rather than a byte.
        await check("unsupported_header_pair_is_refused") {
            guard let blob = DecoderArchiverOracle.archive(oracleSentence as NSString) else {
                return "NSArchiver wrote nothing"
            }
            var wrongSystem = blob
            // Offsets 14–15 are the little-endian system version of a `0x81`-escaped header.
            // Both bytes are written, because the value is a little-endian *pair* and flipping
            // one of them would change the number rather than replace it.
            wrongSystem[wrongSystem.startIndex + 14] = 0x2c
            wrongSystem[wrongSystem.startIndex + 15] = 0x01      // 0x012c = 300
            let body = MessagesDecoder.body(fromAttributedBody: wrongSystem)
            if case .text(let text) = body {
                return "a header with system version 300 decoded to \"\(text)\""
            }
            guard case .unreadable(let reason) = body else { return "body is \(body)" }
            guard case .unsupportedStreamVersion(let found, let system) = reason else {
                return "the refusal is \(reason), not a version refusal"
            }
            guard found == 0x04, system == 300 else {
                return "the refusal names streamer \(found) system \(String(describing: system))"
            }
            return nil
        }

        // 21. Bytes that are not a typedstream at all. A refusal that names *which* fact was
        // wrong is worth having in a bug report; "it did not work" is not.
        await check("not_a_typedstream_is_refused") {
            guard let blob = DecoderArchiverOracle.archive(oracleSentence as NSString) else {
                return "NSArchiver wrote nothing"
            }
            var smashed = blob
            for index in 2..<13 { smashed[smashed.startIndex + index] = 0x20 }
            let body = MessagesDecoder.body(fromAttributedBody: smashed)
            if case .text(let text) = body { return "a smashed signature decoded to \"\(text)\"" }
            guard case .unreadable(let reason) = body else { return "body is \(body)" }
            guard case .notATypedStream(let offset) = reason else { return "the refusal is \(reason)" }
            guard offset == MessagesSchemaVersion.signatureOffset else {
                return "the refusal names offset \(offset)"
            }
            return nil
        }

        // 22. The cap is a refusal, not a truncation and not a stall.
        await check("oversize_is_refused") {
            let body = MessagesDecoder.body(
                fromAttributedBody: Data(count: MessagesDecoder.maxBodyBytes + 1))
            guard case .unreadable(let reason) = body else { return "body is \(body)" }
            guard case .tooLarge(let bytes) = reason, bytes == MessagesDecoder.maxBodyBytes + 1 else {
                return "the refusal is \(reason)"
            }
            return nil
        }

        // MARK: What the corpus cannot answer yet
        //
        // Each of these is an assertion the roadmap names and this corpus cannot support. They
        // are named, not skipped, and none of them is counted.

        block("attributed-body-from-a-real-message",
              "needs one real `attributedBody` from IM-01 (Tests/Reports/imessage-self-flow.md, "
              + "question Q2, experiment 1) with its 16-byte header, its `sw_vers` line and the "
              + "sentence the sender typed. Every `attributedBody` in Tests/Fixtures/chatdb/ is "
              + "the `X'0001'` sentinel, so the decoder has never read a body Messages wrote")
        block("both-paths-decodes-identically",
              "needs the `both-paths` fixture's `attributedBody` replaced with a real stream. Its "
              + "structure, its column-level equality and row B's refusal are green above; the "
              + "positive half — that one sentence decodes the same out of `text` and out of the "
              + "stream — has no real byte to run against")
        block("text-takes-precedence-over-a-decoded-stream",
              "needs a 14th fixture case with `text` AND `attributedBody` both populated on one "
              + "row. The corpus has no such case and TYPEDSTREAM-NOTES.md §3.2 says not to go "
              + "looking for one, so the rule is unpinned rather than assumed")
        block("effect-bubble-classification",
              "needs IM-01 experiment 11, a real effect bubble. The corpus's `reaction` row is a "
              + "tapback and stands in for the `payload_data` + `balloon_bundle_id` pair, which is "
              + "the half that is assertable offline")

        // One string, marker last. `writeSelfTest` writes it in a single call while `print` goes
        // through a buffered stream, so printing the diagnostics separately and returning the
        // marker puts the verdict *before* them on stdout — and a reader, or
        // `Scripts/acceptance.sh`, reads the last line.
        var lines = blocked.map { "IMESSAGE_DECODE_BLOCKED: \($0)" }
        lines.append(contentsOf: failures.map { "IMESSAGE_DECODE_WRONG: \($0)" })
        lines.append(failures.isEmpty
            ? "IMESSAGE_DECODE_OK: \(caseCount) cases"
            : "IMESSAGE_DECODE_FAILED: \(failures[0])")
        return lines.joined(separator: "\n")
    }

    /// One assertion the oracle cases all make: the stream decodes to exactly this, and nothing
    /// else. Inlined rather than a helper per case so a failure names the case it came from.
    private static func expect(_ blob: Data, toDecodeTo expected: String, caseName: String) -> String? {
        switch MessagesDecoder.body(fromAttributedBody: blob) {
        case .text(let text):
            if text == expected { return nil }
            if text.isEmpty { return "\(caseName) decoded to the empty string" }
            if expected.hasPrefix(text) {
                return "\(caseName) decoded to \"\(text)\" — a prefix of \"\(expected)\", "
                    + "\(text.utf8.count) of \(expected.utf8.count) bytes"
            }
            return "\(caseName) decoded to \"\(text)\", expected \"\(expected)\""
        case .unreadable(let reason):
            return "\(caseName) was refused — \(reason)"
        case .notText, .absent:
            return "\(caseName) came back as \(MessagesDecoder.body(fromAttributedBody: blob))"
        }
    }
}

// MARK: - Apple's encoder, used as an oracle

/// `NSArchiver` writes a typedstream, which makes it the one thing in this task that can produce
/// a *real* stream without an iPhone, a human or a Full Disk Access grant.
///
/// **The one deliberate exception `TYPEDSTREAM-NOTES.md` §2.3 sanctions, and it is here in the
/// test rather than in the app.** `NSArchiver` is deprecated (`NSKeyedUnarchiver` is its
/// replacement) and it is still shipped, still working, and takes whatever it is handed. That
/// is the whole value: the bytes are Apple's, so when the decoder recovers the string this
/// process put in, the decoder's mechanics are pinned rather than merely self-consistent.
///
/// It is **not** evidence about what Messages writes — that is IM-01's artefact, and the
/// blocked lines say so by name. And the reason it appears here and not in `MessagesDecoder` is
/// the same reason `TYPEDSTREAM-NOTES.md` §2.2 rejects it for the app at all: it has no throwing
/// entry point, so a stream it dislikes raises an `NSException` that Swift cannot catch. In a
/// self-test that costs the run; inside the message read path it would cost the process.
private enum DecoderArchiverOracle {
    /// One call site for a deprecated API, so the deprecation warning is one line rather than
    /// eight, and so there is exactly one place to delete when Apple finally removes it. The
    /// warning is left standing rather than silenced: it is true, and this file is the one place
    /// in the app where it is the right trade.
    static func archive(_ root: Any) -> Data? {
        NSArchiver.archivedData(withRootObject: root)
    }
}

// MARK: - The fixture corpus

/// `Tests/Fixtures/chatdb/make-chatdb-fixture.sh`, built into a temporary directory.
///
/// The same generator IM-04 uses and for the same reasons: a committed `.sqlite` is a binary no
/// diff can review, and a generated one is deleted with the directory. Nothing is written into
/// the repository and no `.sqlite` is committed. **The generator is not modified by this task**
/// and the corpus carries no real number, name or address — this file reads the sanitised
/// placeholders and writes no fixture value of its own.
private struct DecoderFixtureCorpus {
    /// The DM chat guid shared by most of the cases below.
    static let directChatGUID = "iMessage;-;+15550000001"
    /// The self-conversation's guid, which is where `unsend` puts its rows.
    static let selfChatGUID = "iMessage;-;+15550000000"
    /// `sms` is the one case with no `iMessage` prefix on its chat.
    static let smsChatGUID = "+15550000001"

    struct Fixture: Sendable {
        /// The generator's case name, which is also the file name except when degraded.
        var fixture: String
        /// The file this entry is read from. The generator writes `<case>-degraded.sqlite` for
        /// `--degraded` on its own, so this is not something the test gets to choose.
        var name: String
        var degraded: Bool
        var chatGUID: String
    }

    /// Only the cases this test has a reason to open. `--degraded` is refused by the generator
    /// for the cases that write the two removed columns, so it is asked for by name.
    let cases: [Fixture] = [
        Fixture(fixture: "basic-text", name: "basic-text", degraded: false,
                chatGUID: DecoderFixtureCorpus.directChatGUID),
        Fixture(fixture: "basic-text", name: "basic-text-degraded", degraded: true,
                chatGUID: DecoderFixtureCorpus.directChatGUID),
        Fixture(fixture: "sms", name: "sms", degraded: false, chatGUID: DecoderFixtureCorpus.smsChatGUID),
        Fixture(fixture: "reaction", name: "reaction", degraded: false,
                chatGUID: DecoderFixtureCorpus.directChatGUID),
        Fixture(fixture: "empty-attributed-body", name: "empty-attributed-body", degraded: false,
                chatGUID: DecoderFixtureCorpus.directChatGUID),
        Fixture(fixture: "both-paths", name: "both-paths", degraded: false,
                chatGUID: DecoderFixtureCorpus.directChatGUID),
        Fixture(fixture: "unsend", name: "unsend", degraded: false, chatGUID: DecoderFixtureCorpus.selfChatGUID),
        Fixture(fixture: "voice-note", name: "voice-note", degraded: false,
                chatGUID: DecoderFixtureCorpus.directChatGUID)
    ]

    let directory: URL

    init(directory: URL) { self.directory = directory }

    func url(_ name: String) -> URL {
        directory.appendingPathComponent("\(name).sqlite")
    }

    func discard() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func build() throws -> DecoderFixtureCorpus {
        guard let script = generatorScript() else { throw CorpusError.generatorMissing }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-imessage-decode-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corpus = DecoderFixtureCorpus(directory: directory)
        for entry in corpus.cases {
            var arguments = [script.path, entry.fixture, "--outdir", directory.path]
            if entry.degraded { arguments.append("--degraded") }
            let result = run(arguments)
            guard result.status == 0 else {
                corpus.discard()
                throw CorpusError.buildFailed("\(entry.fixture)\(entry.degraded ? " --degraded" : ""): "
                                              + (result.reason.isEmpty ? "exit \(result.status)" : result.reason))
            }
        }
        return corpus
    }

    enum CorpusError: Error {
        case generatorMissing
        case buildFailed(String)
    }

    /// The checkout this build was compiled from, found the way `MessagesDatabaseSelfTest` finds
    /// it: `#filePath` walks up until the file is there, so the test runs wherever the checkout
    /// lives rather than under whatever the working directory happened to be.
    static func generatorScript() -> URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory
                .appendingPathComponent("Tests")
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("chatdb")
                .appendingPathComponent("make-chatdb-fixture.sh")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private static func run(_ arguments: [String]) -> (status: Int32, reason: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        do { try process.run() } catch {
            return (127, "could not run the generator: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let reason = String(data: data, encoding: .utf8)?
            .split(separator: "\n").map(String.init).joined(separator: " ") ?? ""
        return (process.terminationStatus, reason)
    }

    /// Two rows of `both-paths` with everything that is *not* the body blanked, so a test can
    /// assert that they are the same message read through two columns.
    ///
    /// The five fields it clears are the ones the corpus README names: `ROWID`, `guid`, `date`,
    /// `text` and `attributedBody`. Anything else that differs is a fixture bug, and because
    /// `MessageRow` is `Equatable` a column IM-04 adds later is compared here automatically
    /// rather than silently exempted.
    static func withoutIdentityAndBody(_ row: MessageRow) -> MessageRow {
        var copy = row
        copy.rowID = 0
        copy.guid = ""
        copy.date = nil
        copy.text = nil
        copy.attributedBody = nil
        return copy
    }

    /// A copy of a stream whose declared string length has been made longer than the bytes that
    /// follow it — the out-of-bounds a hand-written parser is most likely to walk into.
    ///
    /// It rewrites the **length byte immediately before the payload** rather than searching for
    /// one, because a length byte is a byte that could be anywhere and picking the wrong one
    /// would test nothing. The payload is located by its own contents, which this process wrote.
    static func stretchDeclaredLength(in blob: Data, payload: String = "FIXTURE-SENTENCE one two three") -> Data? {
        let needle = Array(payload.utf8)
        guard blob.count > needle.count + 1 else { return nil }
        let bytes = [UInt8](blob)
        guard let start = (0..<(bytes.count - needle.count)).first(where: { index in
            Array(bytes[index..<(index + needle.count)]) == needle
        }) else { return nil }
        var stretched = blob
        // 0x7f is the largest single-byte length and is far more than the payload, so the read
        // runs off the end of the buffer — which is the point.
        stretched[stretched.startIndex + start - 1] = 0x7f
        return stretched
    }
}
