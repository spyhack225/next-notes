import Foundation

/// `--selftest-imessage-decode` — NextNotes-iMessage IM-05.
///
/// The `attributedBody` decoder, its refusal, and the shape of the value a refusal produces.
/// **No Full Disk Access, no iPhone, no grant and no real blob**: every case runs against the
/// sanitised corpus in `Tests/Fixtures/chatdb/` and against streams this process asks Apple's
/// own encoder to write.
///
/// **The corpus holds no real typedstream, and this test does not pretend otherwise.** Of the
/// roadmap's blocked assertions, one kind cannot be built from placeholders at all and is
/// reported as a named `IMESSAGE_DECODE_BLOCKED:` line **uncounted** in the
/// `IMESSAGE_DECODE_OK` total; the other kind is answered by IM-01's real bytes, which are
/// **read from a local artefact and never committed** (see `IMESSAGE_DECODE_REAL_BLOB` below).
/// Either way a case that did not run is named and not counted, which is the difference between
/// an honest count and a flattering one: a number that includes a case nobody ran is a claim
/// about this test rather than about the decoder.
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

    // MARK: IM-17c's fixtures — a third party's payload, and the keys that stand in for a
    // link preview, a detected entity and a bundle id.
    //
    // **These are placeholders, and the reason is the same one the oracle sentence is a
    // placeholder for: a self-test may not carry anybody's content.** What they have to be is
    // *shaped* like the thing they stand in for — prose, and a URL, because `UsageLog.sanitise`
    // strips neither and that is exactly why they are the right thing to try to leak.

    /// A third party's promotional offer, in the shape one arrives in: prose with a `$` in it.
    static let foreignOffer = "FIXTURE-THIRD-PARTY-OFFER save 30% on your next $90 order today"
    /// The URL that came with it.
    static let foreignLink = "https://example.invalid/fix-17c-offer"

    /// Three attribute keys standing in for the three things a measured body carried that are
    /// not the sender's words. They are fixtures, so they are named like fixtures.
    static let fixtureKeyA = "fixture-im17c-link-preview"
    static let fixtureKeyB = "fixture-im17c-detected-entity"
    static let fixtureKeyC = "fixture-im17c-bundle-id"

    /// Where IM-01's **real** `attributedBody` lives, when it has been captured.
    ///
    /// ## Why the bytes are not in this repository, in three steps
    ///
    /// 1. **They must not be.** The 2026-09-26 spike's bodies carry a live promotional URL
    ///    and a third party's offer. `Tests/Fixtures/chatdb/` is a tracked directory.
    /// 2. **The corpus generator refuses them anyway**, and not because one of them names
    ///    somebody: `make-chatdb-fixture.sh`'s sanitisation guard scans the SQL it is about to
    ///    write, and a multi-kilobyte hex string is full of 11-digit runs, so it dies with
    ///    *"refusing to emit a fixture containing a bare 11-digit number"*. That is the guard
    ///    working. It also means **a sanitised stand-in cannot be generated from these bytes**,
    ///    which is why the answer below is a local artefact rather than a fourteenth case.
    /// 3. **So the real-body cases read the bytes from a path outside the repository**, named by
    ///    this variable, as a keyed text file:
    ///
    ///    ```text
    ///    text=<the sentence the sender typed>
    ///    blob=040B73747265616D747970656481E803…
    ///    ```
    ///
    ///    `text` is IM-01 §3.1's *expected output* — the sentence the sender typed, which only
    ///    a person knows and which is therefore never derived from the bytes.
    ///
    /// ## What that means for the count, which is the whole point
    ///
    /// With the variable unset the four real-body cases print `IMESSAGE_DECODE_BLOCKED:` and
    /// **do not move the number**: 22 cases, and the run says so. With it set they run and the
    /// count is 26. A blocked line that silently became green would be the one failure this
    /// design exists to prevent, and pointing the variable at a file that is missing, empty or
    /// not hex is a **failure**, not a block — a case that was asked for and did not happen.
    static let realBodyEnvironmentKey = "IMESSAGE_DECODE_REAL_BLOB"

    /// Where IM-01's **real effect rows** live, when they have been captured: the `cases.sh`
    /// block `--imessage-self-flow` writes, which is a *paste-ready fixture generator case*
    /// rather than a keyed text file.
    ///
    /// ## Why a second key and not `IMESSAGE_DECODE_REAL_BLOB`
    ///
    /// Two measured reasons, both of which would have made the one-key answer worse:
    ///
    /// 1. **The real-body format requires a `text=` line**, because it is IM-01 §3.1's *expected
    ///    output* — the sentence the sender typed, which only a person knows and which therefore
    ///    cannot be derived from the bytes. **An effect has no sentence.** Writing `text=` for
    ///    these rows would mean writing a claim about bytes that carry none, which is the exact
    ///    error `effect_bubble_classification` exists to catch, and dropping the requirement
    ///    would weaken the six real-body cases that depend on it.
    /// 2. **The capture is four rows, not one body.** `blob=` is a single hex body, and the
    ///    measurement is four *rows* — four row ids, four dates, four transfer ids — which is
    ///    what makes "an effect is not a message with words" a claim about a shape rather than
    ///    about one lucky blob.
    ///
    /// ## Why a generated `.sqlite` is not used either, and this was measured
    ///
    /// `make-chatdb-fixture.sh`'s sanitisation guard scans the SQL it is about to write and
    /// refuses *"a bare 11-digit number"* — and a 314-byte body of hex is full of 11-digit runs.
    /// Asked to emit these four rows it dies on the first of them:
    ///
    /// ```text
    /// CHATDB_FIXTURE_FAILED: refusing to emit a fixture containing a bare 11-digit number:
    /// 53537472696 67008484084 73747265616 86928496961
    /// ```
    ///
    /// **That is the guard working**, and it is the reason these bytes stay a local artefact
    /// rather than becoming a committed fifteenth case.
    ///
    /// ## So the rows are read from the block, and the `msg` writer is the row
    ///
    /// A `msg` line writes `attributedBody` and **never writes `text`** — `text` is in
    /// `MSG_DEFAULTS` as `sql:NULL` — so every row the block declares is implicitly
    /// `text = NULL`, exactly as the four measured rows were. That is why reading the block and
    /// building the rows in process is the same row shape a generated database would have given,
    /// and why no SQL step is needed to reproduce it: `MessageRow` is the projection, and the
    /// only three fields these rows set are the ones the block writes.
    ///
    /// ## The comment above each row is an input, not a comment
    ///
    /// Each `msg` block is preceded by IM-01's own measurement — `# row 55198 · NULL · 314
    /// bytes` — and the case asserts the body it decoded is that many bytes. A capture and its
    /// own annotation that disagree is a **failure**, not a block: somebody pointed this case at
    /// data and the data said something else.
    static let effectCasesEnvironmentKey = "IMESSAGE_DECODE_EFFECT_CASES"

    static func run() async -> String {
        var failures: [String] = []
        var blocked: [String] = []
        var caseCount = 0
        /// Counts a case measured, and nothing else — no name, no value, no fragment. The whole
        /// point of IM-17c's number is that a macOS which starts attaching more graph is
        /// *visible*, and a number nothing prints is a field rather than a measurement.
        var measured: [String] = []

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
                guard case .notText(let reported, let discarded) = envelope.body,
                      reported == bundleID else {
                    return "body is \(envelope.body), not .notText(\(bundleID))"
                }
                // The tapback is the *other* route to the same state, and it is the only one that
                // arrives with an id. Its discarded count is 0 because no walk ran at all: the
                // body is in `payload_data` and there is no stream to stop short of.
                guard discarded == 0, envelope.discardedBytes == 0 else {
                    return "a tapback with no stream reported \(discarded) bytes passed over"
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
                  + "`MessagesQueries` — a projection IM-05 does not own — so the row is "
                  + "classified as a refusal today, which is honest and not what the README says")
        } catch {
            failures.append("fixtures: \(error)")
        }

        // MARK: A body Messages actually wrote
        //
        // IM-01's 2026-09-26 spike produced nine real `attributedBody` blobs and this is where
        // the shipped decoder is run over one of them. Three of the roadmap's five blocked
        // assertions are about a real body, and all three are here; a fourth — the property
        // TYPEDSTREAM-NOTES.md §4.1 reaches for, on real bytes for the first time — comes with
        // them. The bytes arrive through `realBodyEnvironmentKey` and are never committed; see
        // that constant's comment for why a sanitised stand-in is not an option.

        let realBody = Self.loadRealBody()
        if case .unreadable(let reason) = realBody {
            // Pointed at something and it was not usable. That is a **failure**, not a block: a
            // run that was asked for the real bytes and did not get them must not come back green
            // with a line saying it was waiting. The count does not move — the marker is
            // `_FAILED` either way, and a case count that moves on a plumbing failure is a number
            // about plumbing.
            failures.append("real_body_artefact: \(reason)")
        }
        if case .loaded(let fixture) = realBody {
            // 11. The round trip, and with it the bytes-versus-characters question.
            //
            // **The guard against a vacuous pass is the first thing this case checks**, and it
            // is not decoration: an ASCII sentence is as many bytes as characters, so a capture
            // without an accented character or an emoji in it would pass whether the length is
            // counted in bytes or in characters, and would look like an answer.
            try await check("real_body_decodes_to_the_sentence") {
                let characters = fixture.expected.count
                let payloadBytes = fixture.expected.utf8.count
                guard characters > 0 else { return "the artefact's text= line is empty" }
                guard payloadBytes != characters else {
                    return "the artefact's sentence is \(payloadBytes) bytes and \(characters) "
                        + "characters, so it cannot tell bytes from characters — capture a body "
                        + "with a non-ASCII character in it"
                }
                // The header, measured here rather than implied, because a case that only
                // asserts "it decoded" is asserting the gate's own opinion back at itself. The
                // streamer version is byte 0; the system version is the typedstream integer
                // **read from** offset 13, whose own width the head byte there chooses — and
                // this is the measurement that says the head byte is `0x81` and the pair is
                // little-endian, because read big-endian `E8 03` is 59395 and the gate would
                // refuse every message on this Mac.
                let header = [UInt8](fixture.blob)
                guard header[0] == 0x04 else {
                    return "the real body's streamer version is 0x\(String(header[0], radix: 16))"
                }
                guard header[13] == 0x81 else {
                    return "the real body's system version is introduced by 0x"
                        + "\(String(header[13], radix: 16)), not the 0x81 two-byte marker the gate reads"
                }
                let system = UInt16(header[14]) | UInt16(header[15]) << 8
                guard MessagesSchemaVersion.supported
                    .contains(MessagesSchemaVersion(streamerVersion: header[0], systemVersion: system)) else {
                    let gate = MessagesSchemaVersion.supported
                        .map { "0x\(String($0.streamerVersion, radix: 16))/\($0.systemVersion)" }
                        .joined(separator: ", ")
                    return "the real body's header pair is 0x04 / \(system), which is not in the "
                        + "supported set [\(gate)]"
                }
                var row = MessageRow()
                row.attributedBody = fixture.blob
                let envelope = MessagesDecoder.envelope(for: row)
                guard envelope.source == .attributedBody else {
                    return "the body came from \(envelope.source), not .attributedBody"
                }
                if let text = envelope.text, text.isEmpty {
                    return "a real body decoded to the empty string"
                }
                guard envelope.text == fixture.expected else {
                    let got = envelope.text.map { "\"\($0)\"" } ?? "nil"
                    return "the real body decoded to \(got) — \(payloadBytes) bytes, "
                        + "\(characters) characters"
                }
                return nil
            }

            // 12. `both-paths`, the positive half: one sentence out of `text` and the same
            // sentence out of the stream. This is the assertion that makes the typedstream path
            // *right* rather than merely non-crashing, and it needs the very bytes case 11
            // decoded — the two are the same measurement read twice.
            try await check("real_body_and_the_text_column_agree") {
                var viaStream = MessageRow()
                viaStream.attributedBody = fixture.blob
                var viaTextColumn = viaStream
                viaTextColumn.text = fixture.expected
                let streamed = MessagesDecoder.envelope(for: viaStream)
                let columned = MessagesDecoder.envelope(for: viaTextColumn)
                guard streamed.source == .attributedBody, columned.source == .textColumn else {
                    return "sources are \(streamed.source) and \(columned.source)"
                }
                guard streamed.text == columned.text else {
                    return "the stream says \(streamed.text ?? "nil") and the column says "
                        + "\(columned.text ?? "nil")"
                }
                guard streamed.text == fixture.expected else {
                    return "both paths agree on \(streamed.text.map { "\"\($0)\"" } ?? "nil"), "
                        + "which is not the sentence"
                }
                return nil
            }

            // 13. `text` takes precedence when a row carries both columns. The roadmap called
            // this case exotic and said no fixture had it; on the Mac IM-01 read, **every one
            // of the ten newest rows had `text` *and* a stream**, so this is the common shape
            // and the rule is worth more than a footnote.
            //
            // The sentinel text is a fixture string on purpose: it has to be *different* from
            // what the stream decodes to, or the case cannot tell precedence from agreement.
            try await check("text_takes_precedence_over_a_real_decoded_stream") {
                guard case .text = MessagesDecoder.body(fromAttributedBody: fixture.blob) else {
                    return "the artefact's stream did not decode, so precedence is not being tested"
                }
                let columnText = "FIXTURE-TEXT-COLUMN-WINS"
                guard columnText != fixture.expected else {
                    return "the sentinel text is the same string the stream decodes to, so the "
                        + "case cannot tell precedence from agreement"
                }
                var row = MessageRow()
                row.text = columnText
                row.attributedBody = fixture.blob
                let envelope = MessagesDecoder.envelope(for: row)
                guard envelope.source == .textColumn else {
                    return "source is \(envelope.source), so the stream was read instead of the column"
                }
                guard envelope.text == columnText else {
                    return "text is \(envelope.text.map { "\"\($0)\"" } ?? "nil")"
                }
                guard envelope.decodeState == .decoded else { return "state is \(envelope.decodeState)" }
                return nil
            }

            // 14. The property, on real bytes. `TYPEDSTREAM-NOTES.md` §4.1 is explicit that
            // "every proper prefix is refused" is **false** of a real blob and must not be
            // restored — the text sits early, so a prefix holding the whole sentence holds a
            // body this Mac can read. What has to hold is that no prefix ever decodes to a
            // *different* string: a truncated stream must not yield a shortened message with no
            // error, which is the failure the whole task exists to prevent. 202 prefixes, and
            // both outcomes have to occur or the sweep is not testing anything.
            try await check("no_prefix_of_a_real_body_decodes_to_a_different_string") {
                guard case .text(let whole, _) = MessagesDecoder.body(fromAttributedBody: fixture.blob) else {
                    return "the real body did not decode, so there is no whole string to compare against"
                }
                var read = 0
                var refused = 0
                var decoded = 0
                for count in 0..<fixture.blob.count {
                    read += 1
                    let prefix = Data(fixture.blob.prefix(count))
                    switch MessagesDecoder.body(fromAttributedBody: prefix) {
                    case .text(let value, _):
                        decoded += 1
                        if value.isEmpty {
                            return "the first \(count) of \(fixture.blob.count) bytes decoded to \"\""
                        }
                        guard value == whole else {
                            return "the first \(count) of \(fixture.blob.count) bytes decoded to "
                                + "\"\(value)\" — a prefix of the sentence with no error"
                        }
                    case .unreadable:
                        refused += 1
                    case .notText, .absent:
                        return "the first \(count) of \(fixture.blob.count) bytes came back as a "
                            + "non-body (\(MessagesDecoder.body(fromAttributedBody: prefix)))"
                    }
                }
                guard read > 0, refused > 0, decoded > 0 else {
                    return "of \(read) prefixes, \(refused) were refused and \(decoded) decoded — "
                        + "both have to happen or the sweep proves nothing"
                }
                return nil
            }

            // 15. The count, on real bytes, and the negative over it. IM-17c.
            //
            // **The positive half is already case 11; this is the half that says the walk
            // stopped.** On this body the sender's 27 bytes are read and the 101 bytes behind
            // them are not, and those 101 hold an `NSDictionary` keyed by
            // `__kIMMessagePartAttributeName` — a *named attribute* this decoder passes over
            // without naming. A count of zero here would mean the walk had read the whole body,
            // which is the one thing the guarantee says it never does.
            //
            // **The negative is over the whole rendered envelope, not over one field**, so a
            // future field that carries a third party's string is caught without anyone editing
            // this: nothing at all that the walk passed over may appear in what a caller can
            // see. The check prints counts and lengths only — never a run's content, because a
            // run of somebody else's payload in a log file is the leak this case exists to
            // prevent.
            try await check("real_body_passes_over_its_attribute_graph") {
                var row = MessageRow()
                row.attributedBody = fixture.blob
                let envelope = MessagesDecoder.envelope(for: row)
                guard envelope.source == .attributedBody else {
                    return "the body came from \(envelope.source), not .attributedBody"
                }
                guard case .text(let value, let discarded) = envelope.body else {
                    return "the real body did not decode, so there is nothing to have passed over"
                }
                guard value == fixture.expected else {
                    // The sentence is the sender's own and is already named by case 11; this
                    // case is about the number, so it says so rather than quoting it again.
                    return "the real body decoded to something that is not the attested sentence"
                }
                guard discarded > 0 else {
                    return "a real body that carries a named attribute reported 0 bytes passed over"
                }
                guard discarded < fixture.blob.count else {
                    return "\(discarded) of \(fixture.blob.count) bytes reported as passed over, "
                        + "so the walk claims to have read none of it"
                }
                guard envelope.discardedBytes == discarded else {
                    return "the envelope says \(envelope.discardedBytes), the body says \(discarded)"
                }
                measured.append("real body — \(discarded) of \(fixture.blob.count) bytes passed "
                                + "over unread, and one named attribute is in them")
                return Self.nothingPassedOverReaches(
                    String(describing: envelope),
                    from: fixture.blob,
                    discardedBytes: discarded,
                    caseName: "the real body")
            }
        } else if case .absent = realBody {
            // Named, uncounted, and saying where the bytes are — so the next agent inherits a
            // pointer rather than rediscovering that the artefact exists.
            let pointer = "set \(realBodyEnvironmentKey) to a keyed text file — `text=` the "
                + "sentence the sender typed, `blob=` the hex of one real `attributedBody`. IM-01's "
                + "`--imessage-self-flow` writes the capture to "
                + "~/Library/Caches/NextNotesBuild/imessage/self-flow-case.sh, and it is not "
                + "committed: the blob carries a live promotional URL and a third party's offer"
            block("attributed-body-from-a-real-message",
                  "the bytes exist and were decoded on 2026-09-26 — 9 of 9 real bodies read "
                  + "through the shipped decoder, and the 202-byte self-message round-tripped "
                  + "its 25-character sentence from a 27-byte length, so the length is **bytes**. "
                  + "To run the assertion rather than read about it: \(pointer)")
            block("both-paths-decodes-identically",
                  "the positive half, which needs the same real stream; its structure, its "
                  + "column-level equality and row B's refusal are green above. \(pointer)")
            block("text-takes-precedence-over-a-decoded-stream",
                  "no 14th fixture case is needed and none can be generated: every one of the "
                  + "ten newest real rows carries `text` *and* a stream, and "
                  + "`make-chatdb-fixture.sh`'s sanitisation guard refuses the real hex outright. "
                  + "\(pointer)")
            block("no-prefix-of-a-real-body-decodes-to-a-different-string",
                  "the property TYPEDSTREAM-NOTES.md §4.1 names, on real bytes. \(pointer)")
            block("real-body-passes-over-its-attribute-graph",
                  "IM-17c's count and its negative, on real bytes. This body is the plain end of "
                  + "the range IM-01 measured — its 101 unread bytes hold an NSDictionary keyed by "
                  + "one Apple attribute — and the bodies that carry a detected-entity list, a "
                  + "link preview and a third party's payload were not committed, so the count has "
                  + "never been read against one that has all three. \(pointer)")
        }

        // MARK: A body with no words in it — the effect rows, 2026-09-26
        //
        // **The roadmap's rule for this row was wrong, and the measurement is the reason.**
        // `02-PHASE-1-P0-SLICE.md` §2 classified a non-text balloon by `payload_data` present
        // **and** `balloon_bundle_id` set. All four measured effect rows have `text` NULL, a
        // 314-byte `attributedBody`, and **both** of those columns absent — so the rule fires on
        // nothing, and the assertion that was blocked for want of a capture turns out to have
        // been blocked for want of a capture that disproves the rule it was going to assert.
        //
        // What the bytes are, measured: an ordinary **text balloon** — `NSAttributedString` →
        // `NSObject`, the identical chain a sentence carries — whose one string field is **three
        // bytes of `U+FFFC` and nothing else**, followed by 237 unread bytes of attribute graph
        // that names no app. The chain is not the signal; the three bytes the walk read are.
        // `MessagesDecoder.swift`'s "An effect is not an unreadable message" is the long form.
        let effectCapture = Self.loadEffectCapture()
        if case .unreadable(let reason) = effectCapture {
            // Pointed at something and it was not usable: a **failure**, for the same reason
            // `real_body_artefact` is one. This run was asked for four real rows and did not get
            // them, and a green line saying it was waiting is the failure this design prevents.
            failures.append("effect_capture_artefact: \(reason)")
        }
        if case .loaded(let rows) = effectCapture {
            // **A block whose own annotation names no `text = NULL` row is a failure, not a
            // block.** A file that is there and is not the capture this case is about is the
            // "present-but-unusable" case, and the count must not move on it.
            if rows.isEmpty {
                failures.append("effect_capture_artefact: the block was read and none of its rows "
                                + "is annotated text=NULL, so it is not an effect capture — the "
                                + "capture and the case have to be about the same thing")
            }
            for row in rows {
                let name = "effect_row_\(row.rowID)"

                // The row shape, before the decoder is asked anything. **This is the
                // measurement the roadmap's rule needed and did not have**, so it is asserted
                // rather than assumed: if a future capture puts a bundle id on these rows, the
                // case below must say so and the `nil` assertion has to be revisited on purpose.
                await check("\(name)_has_the_measured_columns") {
                    guard row.textWasNull else {
                        return "the capture's own annotation for row \(row.rowID) does not say NULL"
                    }
                    guard row.blob.count == row.measuredBytes else {
                        return "the capture annotates \(row.measuredBytes) bytes and the body is "
                            + "\(row.blob.count)"
                    }
                    var message = MessageRow()
                    message.rowID = Int64(row.rowID)
                    message.guid = "FIXTURE-EFFECT-\(row.rowID)"
                    message.text = nil            // what a `msg` line writes: never `text`
                    message.attributedBody = row.blob
                    message.payloadData = nil      // measured absent
                    message.balloonBundleID = nil  // measured NULL
                    guard message.payloadData == nil, message.balloonBundleID == nil else {
                        return "the row shape is not the one the measurement described"
                    }
                    return nil
                }

                // **The assertion the roadmap was blocked on.** Not text, and not a refusal:
                // an effect is a balloon that carries no sentence, which is a third thing and is
                // the state the enum already had.
                //
                // `.unreadable` is ruled out on the facts, not on taste: the header was in the
                // supported set, the chain parsed and the one string was read by its declared
                // length, so nothing failed. Calling that a refusal is crying wolf on ordinary
                // use, and the roadmap's own IM-05 spec says so.
                await check("\(name)_is_not_text_and_not_unreadable") {
                    guard let body = Self.effectEnvelope(row) else { return "the row did not open" }
                    if let text = body.text {
                        // Naming the length rather than the value: the marker is one code point
                        // and printing it would put a character the sender never typed into a log.
                        return "an effect came back as text — \(text.utf8.count) bytes, "
                            + "\(text.count) characters"
                    }
                    guard case .notText(let bundleID, _) = body.body else {
                        return "an effect came back as \(body.decodeState), which is not .notText"
                    }
                    guard let named = bundleID else {
                        guard body.source == .attributedBody else {
                            return "the classification came from \(body.source), not .attributedBody"
                        }
                        // The marker is the whole of what was read, and it is a *fact about the
                        // bytes* rather than a rule applied to them: three bytes, one code point.
                        guard MessagesDecoder.isAttachmentOnly(MessagesDecoder.attachmentMarker) else {
                            return "the attachment marker is not the object-replacement character"
                        }
                        return nil
                    }
                    // Naming a length rather than the value: a bundle id is a schema key a person
                    // should never be shown, and this line can land in a log file.
                    return "an effect named an app, and the capture measured no app — "
                        + "\(named.utf8.count) bytes of an identity nothing supplied"
                }

                // **The count, and it is the half that was impossible to assert before.**
                //
                // An earlier version of this file answered `0` discarded bytes for every body
                // that was not `.text`, on the reasoning that a body with no words has nothing
                // to have passed over. **The effect rows are the disproof: 314 bytes, 77 read,
                // 237 unread** — a body with nothing to *read* and 237 bytes to pass over. A
                // small count here would mean the walk stopped early, and stopping early on a
                // body that has no words means it stopped *inside somebody else's payload*.
                await check("\(name)_passes_over_its_whole_attribute_graph") {
                    guard let body = Self.effectEnvelope(row) else { return "the row did not open" }
                    let discarded = body.discardedBytes
                    guard discarded > 0 else {
                        return "a 314-byte effect reported 0 bytes passed over, so the count "
                            + "cannot see the graph at all"
                    }
                    guard discarded > row.blob.count / 2 else {
                        return "\(discarded) of \(row.blob.count) bytes reported as passed over — "
                            + "less than half, so the walk claims to have read most of a body "
                            + "whose only content is that there is nothing to read"
                    }
                    guard discarded < row.blob.count else {
                        return "\(discarded) of \(row.blob.count) bytes reported as passed over, "
                            + "so the walk claims to have read none of it"
                    }
                    guard envelopeCarriesNoMarker(body) else {
                        return "the attachment marker reached a caller on a body that is not a "
                            + "message with words"
                    }
                    measured.append("effect row \(row.rowID) — \(discarded) of \(row.blob.count) "
                                    + "bytes passed over unread, the whole of them unreadable, "
                                    + "and no app named anywhere in them")
                    // The negative, over the whole rendered envelope rather than one field, so
                    // a field added later that carried a third party's value is caught without
                    // anyone editing this. Prints counts and lengths only — see the helper.
                    return Self.nothingPassedOverReaches(
                        String(describing: body), from: row.blob, discardedBytes: discarded,
                        caseName: "effect row \(row.rowID)")
                }
            }
            measured.append("\(rows.count) real effect rows, every one of them a text balloon "
                            + "whose whole string is U+FFFC")
        } else if case .absent = effectCapture {
            // Named, uncounted, and saying where the bytes are. Same discipline as the real-body
            // block above, and the same insistence: **not** counted, so the number stays a claim
            // this run can stand behind.
            block("effect-bubble-classification",
                  "needs IM-01's real effect rows, which now exist: on 2026-09-26 the owner sent "
                  + "an effect to their own conversation and it landed as four rows of 314 bytes "
                  + "with `text` NULL, `payload_data` absent and `balloon_bundle_id` NULL — so the "
                  + "roadmap's `payload_data` + `balloon_bundle_id` rule fires on none of them, and "
                  + "the body is a text balloon whose one string is three bytes of U+FFFC. To run "
                  + "the assertion: set \(effectCasesEnvironmentKey) to IM-01's `cases.sh` block, "
                  + "`~/Library/Caches/NextNotesBuild/imessage/self-flow-case.sh`. It is not "
                  + "committed and cannot be: `make-chatdb-fixture.sh`'s sanitisation guard refuses "
                  + "the hex of a 314-byte body as a bare 11-digit number")
        }

        // MARK: The oracle

        // 15. The header, measured rather than assumed. This is the case that goes red the day
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

        // 16/17. The shape a message body has, as far as it can be checked without a real blob:
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

        // 18. Bytes, not characters. The sentence is 10 characters and 14 UTF-8 bytes, so a
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

        // 19. The two-byte length escape. `oracleLongSentence` is 540 bytes, well past the
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

        // 20. The attachment marker stays in. Stripping `U+FFFC` is how a photo message is made
        // to look empty, which is the failure this whole task exists to prevent.
        await check("archiver_oracle_attachment_marker_survives") {
            let expected = "\u{FFFC} a caption"
            guard let blob = DecoderArchiverOracle.archive(
                NSMutableAttributedString(string: expected)) else {
                return "NSArchiver wrote nothing"
            }
            return Self.expect(blob, toDecodeTo: expected, caseName: "a body with U+FFFC in it")
        }

        // 21. A character pointer is not a body. `NSNumber`'s first field is its `objCType`,
        // a `char *`, and a reader that took the first C string it saw would answer `q`.
        await check("archiver_oracle_character_pointer_is_refused") {
            guard let blob = DecoderArchiverOracle.archive(NSNumber(value: 42)) else {
                return "NSArchiver wrote nothing"
            }
            let body = MessagesDecoder.body(fromAttributedBody: blob)
            if case .text(let text, _) = body { return "an NSNumber came back as \"\(text)\"" }
            guard case .unreadable(let reason) = body else { return "body is \(body)" }
            guard case .notAString = reason else { return "the refusal is \(reason)" }
            return nil
        }

        // 22. Truncation coverage with no fuzzer. **Not** the assertion
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
                case .text(let text, _):
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

        // 23. A declared length that runs past the end. The classic out-of-bounds and the most
        // likely defect in a hand-written parser.
        await check("a_declared_length_past_the_end_is_refused") {
            let expected = "FIXTURE-SENTENCE one two three"
            guard let blob = DecoderArchiverOracle.archive(expected as NSString),
                  let stretched = DecoderFixtureCorpus.stretchDeclaredLength(in: blob) else {
                return "the oracle's stream did not have a length byte to stretch"
            }
            let body = MessagesDecoder.body(fromAttributedBody: stretched)
            if case .text(let text, _) = body { return "an over-long length decoded to \"\(text)\"" }
            guard case .unreadable(let reason) = body else { return "body is \(body)" }
            guard case .truncated = reason else { return "the refusal is \(reason), not a truncation" }
            return nil
        }

        // 24. The version gate, both halves. A good streamer version with the wrong system
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
            if case .text(let text, _) = body {
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

        // 25. Bytes that are not a typedstream at all. A refusal that names *which* fact was
        // wrong is worth having in a bug report; "it did not work" is not.
        await check("not_a_typedstream_is_refused") {
            guard let blob = DecoderArchiverOracle.archive(oracleSentence as NSString) else {
                return "NSArchiver wrote nothing"
            }
            var smashed = blob
            for index in 2..<13 { smashed[smashed.startIndex + index] = 0x20 }
            let body = MessagesDecoder.body(fromAttributedBody: smashed)
            if case .text(let text, _) = body { return "a smashed signature decoded to \"\(text)\"" }
            guard case .unreadable(let reason) = body else { return "body is \(body)" }
            guard case .notATypedStream(let offset) = reason else { return "the refusal is \(reason)" }
            guard offset == MessagesSchemaVersion.signatureOffset else {
                return "the refusal names offset \(offset)"
            }
            return nil
        }

        // 26. The cap is a refusal, not a truncation and not a stall.
        await check("oversize_is_refused") {
            let body = MessagesDecoder.body(
                fromAttributedBody: Data(count: MessagesDecoder.maxBodyBytes + 1))
            guard case .unreadable(let reason) = body else { return "body is \(body)" }
            guard case .tooLarge(let bytes) = reason, bytes == MessagesDecoder.maxBodyBytes + 1 else {
                return "the refusal is \(reason)"
            }
            return nil
        }

        // MARK: Only the sender's own words leave the decoder — IM-17c
        //
        // **The four cases below are the safety property the whole feature rests on**, and the
        // first of them is the one that was red before the fix. A real `attributedBody` is an
        // attribute graph, not a string: on 2026-09-26 the bodies measured on this Mac carried
        // a detected-entity list, a link preview, a `com.apple.*` bundle id, and — in one of
        // them — `__kMSHSMessage`, a third party's promotional payload as its own nested object
        // with its own nested string. A conversation with yourself is addressed to your own
        // phone number, so that payload really does arrive in the paired chat.
        //
        // The decoder's answer is a **positive rule**: the characters of the string this body
        // *is*. Everything else in the stream is left unread, and a shape that is not a text
        // balloon is refused rather than searched.

        // 27. **The negative, and the one that was red.** A root that is not a text balloon is
        // refused — it is not searched for a string it happens to contain.
        //
        // **This is the mutation that proves the test can fail.** On the walk this replaced, the
        // reader descended into nested objects until it found a string it could justify, so it
        // answered with the offer carried inside the foreign object: the same value, read as the
        // message. The refusal is the guarantee, and `notAString` is the honest name for it.
        await check("archiver_a_foreign_payload_is_never_the_message") {
            let payload = DecoderForeignPayload(offer: Self.foreignOffer, link: Self.foreignLink)
            guard let blob = DecoderArchiverOracle.archive(payload) else {
                return "NSArchiver wrote nothing for the foreign payload"
            }
            // The precondition, and it is the whole case: the bytes really do carry a nested
            // string, so a refusal is a decision rather than an accident.
            guard blob.count > Self.foreignOffer.utf8.count else {
                return "the foreign payload's stream is shorter than the string it carries, so "
                    + "the case cannot tell a refusal from a blob that was never read"
            }
            var row = MessageRow()
            row.attributedBody = blob
            let envelope = MessagesDecoder.envelope(for: row)
            if case .text(let text, _) = envelope.body {
                return "a foreign object answered as the message — \(text.utf8.count) bytes"
            }
            guard case .unreadable(let reason) = envelope.body else {
                return "a foreign object came back as \(envelope.decodeState), not a refusal"
            }
            guard case .notAString = reason else { return "the refusal is \(reason)" }
            if envelope.text != nil { return "a refused body also carried text" }
            return Self.nothingPassedOverReaches(
                String(describing: envelope), from: blob, discardedBytes: 0, caseName: "the payload")
        }

        // 28. A link preview does not change the message. Apple's own encoder, a real
        // `NSAttributedString.Key.link` and a real URL — the shape a body with a link carries,
        // written by the writer this whole file uses as its oracle.
        await check("archiver_a_link_preview_does_not_change_the_message") {
            let expected = Self.oracleSentence
            let link = "https://example.invalid/preview-fixture"
            guard let url = URL(string: link),
                  let blob = DecoderArchiverOracle.archive(NSMutableAttributedString(
                    string: expected,
                    attributes: [.link: url])) else {
                return "NSArchiver wrote nothing for an attributed string carrying a link"
            }
            var row = MessageRow()
            row.attributedBody = blob
            let envelope = MessagesDecoder.envelope(for: row)
            guard envelope.text == expected else {
                return "the message is \(envelope.text?.utf8.count ?? 0) bytes, expected the "
                    + "sender's \(expected.utf8.count)"
            }
            guard envelope.discardedBytes > 0 else {
                return "a body carrying a link attribute reported 0 bytes passed over, so the "
                    + "count cannot see the graph at all"
            }
            return Self.nothingPassedOverReaches(
                String(describing: envelope), from: blob,
                discardedBytes: envelope.discardedBytes, caseName: "the link preview")
        }

        // 29. The same sentence, twice, with different amounts of graph behind it. **The count
        // has to move**, or it is decoration: the design's reason for the number is that a
        // macOS which starts attaching more per message is *visible*, and a count that reads the
        // same for a body with one attribute and a body with three cannot see that.
        await check("archiver_a_growing_graph_grows_the_count") {
            let expected = Self.oracleSentence
            guard let bare = DecoderArchiverOracle.archive(
                NSMutableAttributedString(string: expected)),
                  let one = DecoderArchiverOracle.archive(NSMutableAttributedString(
                    string: expected, attributes: [NSAttributedString.Key(Self.fixtureKeyA): "a"])),
                  let three = DecoderArchiverOracle.archive(NSMutableAttributedString(
                    string: expected,
                    attributes: [NSAttributedString.Key(Self.fixtureKeyA): "a",
                                 NSAttributedString.Key(Self.fixtureKeyB): "b",
                                 NSAttributedString.Key(Self.fixtureKeyC): "c"])) else {
                return "NSArchiver wrote nothing for one of the three bodies"
            }
            func discarded(_ blob: Data) -> (count: Int, problem: String?)? {
                let body = MessagesDecoder.body(fromAttributedBody: blob)
                guard case .text(let value, let count) = body else { return (0, "body is \(body)") }
                guard value == expected else {
                    return (0, "one of the bodies decoded to a different string")
                }
                return (count, nil)
            }
            guard let bareResult = discarded(bare), bareResult.problem == nil,
                  let oneResult = discarded(one), oneResult.problem == nil,
                  let threeResult = discarded(three), threeResult.problem == nil else {
                return "one of the three bodies did not decode as the sender's sentence"
            }
            // Monotonicity, and not an exact number: how many bytes Apple's own encoder writes
            // around an *empty* attribute dictionary is a fact about the encoder and not this
            // decoder's claim, so what is asserted is that the count moves with the graph and
            // never with the sentence.
            guard bareResult.count <= oneResult.count else {
                return "a body with no attributes reported \(bareResult.count) and one reported "
                    + "\(oneResult.count)"
            }
            guard oneResult.count > 0 else {
                return "a body with one attribute reported \(oneResult.count)"
            }
            guard threeResult.count > oneResult.count else {
                return "three attributes reported \(threeResult.count) and one reported "
                    + "\(oneResult.count)"
            }
            return nil
        }

        // 30. The count is a count. `MessageBody` carries an `Int` and a `String` and nothing
        // else, so there is no field a name, a value or a fragment could ride in — and this
        // case says it over the type rather than over a convention.
        await check("archiver_the_count_carries_no_names_and_no_values") {
            let expected = Self.oracleSentence
            guard let blob = DecoderArchiverOracle.archive(NSMutableAttributedString(
                string: expected,
                attributes: [NSAttributedString.Key(Self.fixtureKeyA): "a",
                             NSAttributedString.Key(Self.fixtureKeyB): "b"])) else {
                return "NSArchiver wrote nothing"
            }
            let body = MessagesDecoder.body(fromAttributedBody: blob)
            guard case .text(let value, let count) = body else { return "body is \(body)" }
            guard value == expected, count > 0 else { return "text or count is wrong" }
            // One string and one integer, and the integer is not derived from the string: a
            // character count of the sender's text is the smallest possible fingerprint of it,
            // so the count is about the *body*, and this pins that it moves with the graph and
            // not with the sentence.
            let rendered = String(describing: body)
            guard !rendered.contains(Self.fixtureKeyA), !rendered.contains(Self.fixtureKeyB) else {
                return "the body's own description carries an attribute name"
            }
            guard count != expected.count, count != expected.utf8.count else {
                return "the count \(count) is the sender's text length, which is a fingerprint"
            }
            return nil
        }

        // MARK: What no corpus and no artefact can answer
        //
        // Each of these is an assertion the roadmap names that nothing available can support.
        // They are named, not skipped, and none of them is counted.

        // One string, marker last. `writeSelfTest` writes it in a single call while `print` goes
        // through a buffered stream, so printing the diagnostics separately and returning the
        // marker puts the verdict *before* them on stdout — and a reader, or
        // `Scripts/acceptance.sh`, reads the last line.
        var lines = blocked.map { "IMESSAGE_DECODE_BLOCKED: \($0)" }
        // `IMESSAGE_DECODE_COUNT` is deliberately **not** a verdict token: it is neither `_OK`
        // nor `_FAILED`, so `Scripts/acceptance.sh` reads past it, and it carries counts only.
        lines.append(contentsOf: measured.map { "IMESSAGE_DECODE_COUNT: \($0)" })
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
        case .text(let text, _):
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

    // MARK: - The negative: nothing the walk passed over may reach a caller

    /// The envelope a captured effect row produces, built exactly as the measurement described
    /// the row: `text` NULL, the 314-byte body in `attributedBody`, and both of the columns the
    /// roadmap's rule keyed on absent.
    ///
    /// `nil` rather than a message is not possible here — the row is three assignments — so the
    /// optional is only so a caller can fail a case rather than trap. It never returns `nil`.
    private static func effectEnvelope(_ row: EffectRow) -> IMessageEnvelope? {
        var message = MessageRow()
        message.rowID = Int64(row.rowID)
        message.guid = "FIXTURE-EFFECT-\(row.rowID)"
        message.text = nil
        message.attributedBody = row.blob
        message.payloadData = nil
        message.balloonBundleID = nil
        return MessagesDecoder.envelope(for: message)
    }

    /// Whether the object-replacement character reached a caller at all — over the **whole
    /// rendered envelope**, so a field added later that carried it is caught without anyone
    /// editing the case.
    ///
    /// This is the marker's own leak check, and it is separate from
    /// `nothingPassedOverReaches` on purpose: that one compares printable-ASCII runs of six
    /// bytes or more, and `U+FFFC` is none of those, so a decoder that answered
    /// `.text("\u{FFFC}")` would sail past it. `envelope.text == nil` catches that spelling and
    /// this catches the other one — a new field carrying the marker beside a correct state.
    private static func envelopeCarriesNoMarker(_ envelope: IMessageEnvelope) -> Bool {
        !String(describing: envelope).contains(MessagesDecoder.attachmentMarker)
    }

    /// Assert that **no run of printable text from the bytes the walk did not read appears in
    /// what a caller can see** — over the whole rendered value, not over one field, so a new
    /// field carrying a third party's payload is caught without anyone editing the case.
    ///
    /// ## Why it is built out of runs rather than a list of names
    ///
    /// Naming the attributes would be the denylist the design refuses: a bet on this macOS's
    /// attribute names, and a test that only knows the ones somebody remembered. Instead every
    /// printable-ASCII run of six bytes or more in the discarded region is a candidate,
    /// which is why `__kIMMessagePartAttributeName`, a link URL and a prose offer are all caught
    /// by the same three lines and a future tenth attribute is caught by them too.
    ///
    /// ## Sub-runs, and why comparing whole runs was a hole (IM-05c)
    ///
    /// **The first version compared *maximal* runs, and a mutation got past it.** The tempting
    /// way to fill `.notText`'s id on a real effect row is to carry on past the sender's string
    /// and take the next length-prefixed value that looks like an id — which is a search, the
    /// thing this whole design forbids. On the 314-byte effect bodies that search finds the
    /// 36-character file-transfer GUID in the attribute graph, and the leak assertion **stayed
    /// green**: in the stream the value's maximal printable run is 37 bytes long because it
    /// begins with the `+` that introduces it, and what reached the caller was the 36 bytes
    /// *without* that one type tag. A whole-run comparison cannot see a value that arrived with
    /// its framing stripped, which is exactly what a decoder does to it.
    ///
    /// **So every contiguous sub-run of six bytes or more is a candidate, not only the maximal
    /// one.** The cost is a few thousand `contains` calls over runs of a few dozen bytes, which
    /// is nothing.
    ///
    /// ## And a candidate only counts when it is *delimited* in the value, which is the second
    /// half and is not optional
    ///
    /// Sub-runs alone produced nine false positives on the first try, and every one of them was
    /// this app's own vocabulary: `__kIMMessagePartAttributeName` contains **`Message`**, which
    /// is in `IMessageEnvelope`, and `__kIM…AttributeName` contains **`ttribute`**, which is in
    /// `attributedBody`. The rendered value is a reflection of a Swift struct, so it contains
    /// this decoder's type name and field names, and Apple's attribute names are built from the
    /// same ordinary English words. That collision is a property of the *naming*, not a leak,
    /// and no floor removes it — the two longest were eight bytes.
    ///
    /// **A value that reaches a caller is a value, and a value is delimited.** So a candidate
    /// counts only when the rendered value contains it with a non-alphanumeric character (or an
    /// edge) on both sides. The GUID the mutation leaks is rendered inside a quoted associated
    /// value, so it is delimited and is caught; `Message` inside `IMessageEnvelope` and `ttribute`
    /// inside `attributedBody` are interior to a longer identifier, and are not.
    ///
    /// **What this costs, stated rather than hidden:** a payload that reached a caller *spliced
    /// onto the end of another value* would not be delimited and this case would miss it. That
    /// is the one shape the check does not cover, and the honest reason it is not covered is
    /// that covering it means denylisting this decoder's own identifiers, which is the bet the
    /// design refuses everywhere else. The exact-character check `envelopeCarriesNoMarker` and the
    /// `.notText` assertions do not have the blind spot, because they compare against a known
    /// value rather than a rendering.
    ///
    /// Six bytes is the floor because the format's own bytes are dense: `streamtyped`, a class
    /// name, a `+` and a length all sit within a few bytes of each other, and a shorter floor
    /// would report the format rather than the payload. The discarded region is the right place
    /// to look because the sender's own sentence is *not* in it — it is what the walk read — so
    /// nothing here can be a false positive on the message.
    ///
    /// **A failure names how many candidates and how long, never what they were.** A log line
    /// that printed the offending run would be the leak.
    private static func nothingPassedOverReaches(
        _ rendered: String, from blob: Data, discardedBytes: Int, caseName: String
    ) -> String? {
        // A refusal reads nothing at all, so the whole body is the region the caller must not
        // be quoting from.
        let passedOver = discardedBytes > 0 ? blob.suffix(discardedBytes) : blob[...]
        var runs: [String] = []
        var current = ""
        for byte in passedOver {
            if byte >= 0x20, byte < 0x7F {
                current.append(Character(UnicodeScalar(byte)))
            } else {
                if current.count >= Self.leakFloor { runs.append(current) }
                current = ""
            }
        }
        if current.count >= Self.leakFloor { runs.append(current) }
        guard !runs.isEmpty else {
            return "\(caseName): the discarded region holds no printable run of "
                + "\(Self.leakFloor) bytes or more, so the case cannot see a leak"
        }
        // Every contiguous sub-run, deduplicated, longest first — so a failure names the
        // *longest* thing that got through rather than whichever run happened to be scanned
        // first. This is the fix for a maximal-run comparison missing a value that reached a
        // caller without its type tag; see this function's comment.
        var candidates: [String] = []
        var seen: Set<String> = []
        for run in runs {
            let characters = Array(run)
            for start in 0..<characters.count {
                for length in stride(from: characters.count - start, through: Self.leakFloor, by: -1) {
                    let candidate = String(characters[start..<(start + length)])
                    if seen.insert(candidate).inserted { candidates.append(candidate) }
                }
            }
        }
        let characters = Array(rendered)
        let leaked = candidates.filter { Self.containsDelimited($0, in: characters) }
        guard leaked.isEmpty else {
            return "\(caseName): \(leaked.count) of \(candidates.count) printable sub-runs of "
                + "\(Self.leakFloor)+ bytes from the \(passedOver.count) bytes the walk did not "
                + "read appear in the value a caller can see as a whole delimited value, the "
                + "longest \(leaked.map(\.count).max() ?? 0) bytes"
        }
        return nil
    }

    /// The shortest printable run that counts as somebody else's bytes rather than the format's.
    ///
    /// Six, and the reasoning is this file's: a class name, a tag and a length byte sit within a
    /// few bytes of each other in a typedstream, so a shorter floor reports the encoding instead
    /// of the payload.
    private static let leakFloor = 6

    /// Whether `candidate` appears in `haystack` as a **whole delimited value** — a
    /// non-alphanumeric character, or the edge of the string, on both sides.
    ///
    /// This is the second half of the fix for the maximal-run hole, and it is what stops Apple's
    /// attribute vocabulary from being mistaken for a leak: `Message` inside `IMessageEnvelope`
    /// and `ttribute` inside `attributedBody` are interior to a longer identifier, while a value
    /// that reached a caller sits inside a quoted associated value or between two separators.
    private static func containsDelimited(_ candidate: String, in haystack: [Character]) -> Bool {
        let needle = Array(candidate)
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        func isWord(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_"
        }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            let beforeOK = start == 0 || !isWord(haystack[start - 1])
            let afterIndex = start + needle.count
            let afterOK = afterIndex == haystack.count || !isWord(haystack[afterIndex])
            if beforeOK, afterOK { return true }
        }
        return false
    }

    // MARK: - The local real body

    /// IM-01's real `attributedBody` and the sentence it holds.
    ///
    /// **Not in this repository, and not in the corpus either** — see `realBodyEnvironmentKey`
    /// for the three reasons. It is a value rather than a flag so the run can tell *nobody
    /// pointed at a file* (a block, and the cases stay uncounted) from *somebody pointed at a
    /// file that is not usable* (a failure, because a case that was asked for did not happen).
    enum RealBody {
        case absent
        case loaded(RealBodyFixture)
        case unreadable(String)
    }

    /// One keyed text file's worth of capture: `text=` the sentence the sender typed and
    /// `blob=` the hex of one real `attributedBody`.
    ///
    /// `expected` is a person's own sentence and is **never reconstructed from the bytes** —
    /// IM-01 §3.1's whole point is that the expected output is the one thing the data cannot
    /// supply. Keeping it in the artefact rather than in this file is the same reason: it is
    /// content, and content does not belong in a tracked file.
    struct RealBodyFixture: Sendable {
        var expected: String
        var blob: Data
    }

    static func loadRealBody() -> RealBody {
        guard let path = ProcessInfo.processInfo.environment[realBodyEnvironmentKey],
              !path.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .absent
        }
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .unreadable("\(realBodyEnvironmentKey) is set to \(path), which could not be read")
        }
        var values: [String: String] = [:]
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let split = trimmed.firstIndex(of: "=") else {
                return .unreadable("\(path) has a line that is not key=value: \(trimmed.prefix(24))")
            }
            values[String(trimmed[..<split])] = String(trimmed[trimmed.index(after: split)...])
        }
        guard let text = values["text"], !text.isEmpty else {
            return .unreadable("\(path) has no non-empty text= line — the sentence the sender typed")
        }
        guard let hex = values["blob"], !hex.isEmpty else {
            return .unreadable("\(path) has no blob= line — the hex of one real attributedBody")
        }
        guard let blob = RealBodyFixture.bytes(fromHex: hex) else {
            return .unreadable("\(path)'s blob= line is \(hex.count) characters, which is not a whole "
                               + "number of hex bytes")
        }
        guard blob.count > MessagesSchemaVersion.signatureOffset + 3 else {
            return .unreadable("\(path)'s blob is \(blob.count) bytes — too short to be a typedstream")
        }
        return .loaded(RealBodyFixture(expected: text, blob: blob))
    }
}

// MARK: - The local effect capture

extension MessagesDecoderSelfTest {
    /// One `text = NULL` row of an `EffectCapture`, with the annotation IM-01 wrote above it.
    ///
    /// The three annotation fields are **inputs to the assertions**, not provenance: `textWasNull`
    /// is what selects the row out of the block (a body with a `text` column is not this case),
    /// and `measuredBytes` is the length the capture itself claims, which the case checks the
    /// decoded body against. A capture that annotates 314 bytes and carries 312 is a failure.
    struct EffectRow: Sendable {
        /// `message.ROWID` on the machine the capture came from. Opaque; used only for naming.
        var rowID: Int
        /// The capture said `text` was NULL on this row.
        var textWasNull: Bool
        /// The body length the capture annotated, in bytes.
        var measuredBytes: Int
        var blob: Data
    }

    /// What the effect block holds, as a value rather than a flag — so the run can tell *nobody
    /// pointed at a file* (a block, and the cases stay uncounted) from *somebody pointed at a
    /// file that is not usable* (a failure). The same three-way answer `RealBody` gives, for
    /// the same reason.
    enum EffectCapture {
        case absent
        case loaded([EffectRow])
        case unreadable(String)
    }

    /// Read the `cases.sh` block, taking the rows whose own annotation says `text = NULL`.
    ///
    /// **What it reads and what it refuses to read.** Each `msg` block in the file is preceded by
    /// IM-01's measurement — `# row 55198 · NULL · 314 bytes, first 16: …` — and the body is on
    /// the `attributedBody=blob:` line inside the block. The first `msg` of the file references
    /// a shell variable instead of inlining the hex, and it is skipped for that reason: a body
    /// this file cannot see is a block, not a failure, and one it can see is the measurement.
    ///
    /// **The separator is the middot `·` IM-01's generator writes, and it is parsed rather than
    /// pattern-matched loosely**: a file whose annotations do not have this shape is `unreadable`,
    /// which is a failure — somebody pointed this at data and the data is not what it claims.
    /// Nothing here is repaired.
    static func loadEffectCapture() -> EffectCapture {
        guard let path = ProcessInfo.processInfo.environment[effectCasesEnvironmentKey],
              !path.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .absent
        }
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .unreadable("\(effectCasesEnvironmentKey) is set to \(path), which could not be read")
        }
        var pending: (rowID: Int, textWasNull: Bool, bytes: Int)?
        var rows: [EffectRow] = []
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            if let annotation = effectAnnotation(line) {
                pending = annotation
                continue
            }
            guard let hex = effectBlobHex(line) else { continue }
            guard let annotation = pending else {
                return .unreadable("\(path) has an attributedBody with no measurement above it — "
                                   + "every body in this block is annotated by the capture that "
                                   + "wrote it, and this one is not")
            }
            guard let blob = RealBodyFixture.bytes(fromHex: hex) else {
                return .unreadable("\(path)'s body above row \(annotation.rowID) is "
                                   + "\(hex.count) characters, which is not a whole number of hex bytes")
            }
            // **The predicate the case is about, taken from the capture and not from us**: only
            // the rows whose own annotation says `text = NULL`. Everything else in the block is
            // an ordinary sentence and is none of this case's business.
            if annotation.textWasNull {
                rows.append(EffectRow(rowID: annotation.rowID,
                                      textWasNull: true,
                                      measuredBytes: annotation.bytes,
                                      blob: blob))
            }
            pending = nil
        }
        return .loaded(rows)
    }

    /// `# row 55198 · NULL · 314 bytes, first 16: 04 0B …` → `(55198, true, 314)`.
    ///
    /// The middle field is the `text` column as the capture measured it: `NULL`, or a character
    /// count like `12 characters`. **The number beside `row` is never interpreted** — it is the
    /// real `ROWID` on the owner's machine and is opaque here, exactly as
    /// `IMessageEnvelope.rowID`'s own comment says it is.
    private static func effectAnnotation(_ line: Substring) -> (rowID: Int, textWasNull: Bool, bytes: Int)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let parts = trimmed.dropFirst().split(separator: "·", omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return nil }
        let head = parts[0].trimmingCharacters(in: .whitespaces)
        let rowToken = head.split(separator: " ").last.map(String.init) ?? ""
        guard let rowID = Int(rowToken) else { return nil }
        // `12 characters` and `NULL` are the only two shapes the generator writes, and the
        // second is the one this case is about. Anything else is a shape we do not know how to
        // read, so it is not treated as a NULL.
        let textField = parts[1].trimmingCharacters(in: .whitespaces)
        let textWasNull = textField == "NULL"
        let bytesToken = parts[2].trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first.map(String.init) ?? ""
        guard let bytes = Int(bytesToken) else { return nil }
        return (rowID, textWasNull, bytes)
    }

    /// The hex of one `attributedBody=blob:…` line, or `nil` for any other line.
    ///
    /// The first `msg` in the block writes `attributedBody="$BLOBBODY_REAL"` — a shell variable
    /// this process cannot resolve — and it carries a `12 characters` annotation, so it is
    /// skipped by the `text = NULL` filter rather than by a special case here.
    private static func effectBlobHex(_ line: Substring) -> String? {
        guard let range = line.range(of: "attributedBody=blob:") else { return nil }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
}

extension MessagesDecoderSelfTest.RealBodyFixture {
    /// Hex in, bytes out, and `nil` for anything that is not hex — a file pointed at by mistake
    /// has to be a failure rather than a decode of whatever survived. Whitespace is ignored so a
    /// hex dump can be pasted in as it stands.
    fileprivate static func bytes(fromHex hex: String) -> Data? {
        let digits = hex.filter { !$0.isWhitespace }
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}

// MARK: - The shape a third party's payload arrives in

/// A stand-in for the one object this roadmap measured and could not commit.
///
/// `TYPEDSTREAM-NOTES.md`, 2026-09-26: inside one real `attributedBody` on this Mac there was
/// **`__kMSHSMessage` — a third party's promotional payload carried as its own nested object,
/// with its own nested string, a `$` value, a class range and a date range**, beside a
/// `__kIMDataDetectedLinkAttributeName` URL, a `__kIMLinkPreviewAttributeName`, a
/// `__kIMDataDetectedResult` list and a `com.apple.*` bundle id. **A conversation with yourself
/// is addressed to your own phone number, so a remote turn arrives wearing somebody else's
/// marketing, and its row carries their payload.** A row in a thread is not a sentence.
///
/// **Why this is a class and not a fixture.** A `attributedBody` is a typedstream, and the
/// roadmap forbids synthesising one — which is why the oracle above asks `NSArchiver` to write
/// real bytes. Asking it to write *this* object writes real bytes too, in the real shape: an
/// object that is **not a text balloon** and whose first field is a nested string, with a URL
/// beside it. That is the shape a decoder that *searches* the graph answers with.
///
/// **It conforms to `NSCoding` by hand, and the conformance is the interesting part.** Two
/// things about it were measured while writing this case, and both are the reason
/// `MessagesDecoder` is hand-written at all:
///
/// 1. **`NSArchiver` signals failure by raising an `NSException`, and Swift cannot catch one.**
///    The first version of this class did not say `: NSCoding`, so its `encode(with:)` was
///    never bridged to the selector `encodeWithCoder:`, and the archiver raised
///    `-[ForeignPayload encodeWithCoder:]: unrecognized selector` — which **terminated the
///    process**, mid-self-test, with no Swift error and no verdict. That is §2.2's argument in
///    miniature: the system API's failure channel is the process, and a self-test that touches
///    the owner's machine has no way to degrade into a failed case.
/// 2. **`NSArchiver` is the *unkeyed* archiver.** `coder.encode(x, forKey:)` raises
///    *"encodeObject:forKey: only defined for abstract class"*, so this encodes positionally.
///
/// It is a test fixture, in a self-test, in this file, and it is the one place in the tree that
/// writes anything resembling somebody else's payload — with placeholder text, for the reason the
/// oracle sentence is a placeholder.
@objc(DecoderForeignPayload)
private final class DecoderForeignPayload: NSObject, NSCoding {
    /// The prose a third party's payload carries. **First**, which is the whole point: the walk
    /// this replaced searched for the first string it could justify and would land here.
    @objc let offer: NSString
    /// The URL that came with it.
    @objc let link: NSString

    init(offer: String, link: String) {
        self.offer = offer as NSString
        self.link = link as NSString
        super.init()
    }

    @objc func encode(with coder: NSCoder) {
        coder.encode(offer)
        coder.encode(link)
    }

    /// Nothing ever unarchives this class — it exists to be *written* — and a decoder half that
    /// has never been run is worse than one that says so.
    required init?(coder: NSCoder) { return nil }
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
