import Foundation

/// `message.attributedBody` → text, or an honest refusal.
///
/// **Written against macOS 27.0 (26A428), typedstream header `04` / system `1000`** — the
/// same thing `KnowledgeStore` records as its `user_version`, and for the same reason: a
/// format that changes under you has to be *named* in the file, not remembered in it.
///
/// **What this is not.** It is not a general typedstream reader. It is a reader for the one
/// shape Messages writes — a text balloon — and it refuses everything else. The refusal is
/// the feature: `text` is `nil` and `decodeState` says why, so nothing downstream can read a
/// message this Mac could not read as a blank one, and a person is told a sentence arrived
/// instead of silence. `IMessageEnvelope` makes that structural rather than conventional: one
/// stored `MessageBody`, and `text` and `decodeState` are *derived* from it, so they cannot
/// drift and `.unreadable` has no spelling that is the empty string.
///
/// **Why a hand-written parser and not `NSUnarchiver`.** The system API that can read a
/// typedstream has no throwing entry point; it signals failure by raising an `NSException`,
/// which Swift cannot catch. A macOS release that changed the format would therefore exit the
/// process inside the message read path, on the user's own machine, at the exact moment the
/// designed response is "degrade the feature and say so". A value is the only failure mode
/// that can be degraded *to*. `TYPEDSTREAM-NOTES.md` §2 makes the case in full; this file is
/// the decision, and the version gate is therefore **data** (`MessagesSchemaVersion.supported`,
/// a `Set` a future macOS extends by one line) rather than a branch.
///
/// **What is measured, and what is still inference.** TYPEDSTREAM-NOTES.md labels every claim
/// in it, and its one blocking `[UNMEASURED]` item is whether the header pair is still
/// `04` / `1000`. That is now measured **for Apple's own encoder on this Mac**: on 2026-09-25,
/// `NSArchiver.archivedData(withRootObject:)` wrote `04 0b "streamtyped" 81 e8 03` for every
/// root object tried — `NSString`, `NSMutableString`, `NSAttributedString`,
/// `NSMutableAttributedString`, with and without attribute runs. So `04` / `1000` is a
/// measurement, not a guess. **It is not a measurement of what Messages writes**, which is
/// the different question, and it cannot be: `~/Library/Messages/` answers *Operation not
/// permitted* on this machine. Three more things fell out of the same experiment and are
/// implemented as measured rather than as published:
///
/// - **The string length is a UTF-8 *byte* count.** A payload of `héllo 🌍 ok` is prefixed
///   `0x0e` (14) while the string is 10 characters. A decoder that assumed characters would
///   truncate exactly the messages with an emoji in them.
/// - **The length escapes to `0x81` + little-endian `u16` above 127**, and the escape is not
///   chosen on size: bytes `0x80`–`0x8F` are the *tag* range, so a value that would land
///   there is written in two bytes even though it fits in one. Reading it as "one byte if it
///   fits" silently truncates a 292-byte message to 36 bytes.
/// - **The text is the first field of a nested `NSMutableString`, and the class chain names
///   it.** `NSAttributedString` writes its string before its attribute runs, so this reader
///   takes the first field of the nested string object and stops. A root whose first field is
///   a *character pointer* is refused rather than read: `NSNumber`'s `objCType` is a `char *`,
///   and a reader that took the first C string it saw would answer `q`.
///
/// **Three places this file departs from `TYPEDSTREAM-NOTES.md` §5.1, each for a reason:**
///
/// 1. `MessageDecodeFailure.unsupportedStreamVersion(system:)` takes an **optional** system
///    version. The corpus's `X'0001'` sentinel is two bytes, so the version byte is there and
///    the system version is not, and writing `0` for a pair of bytes that do not exist would
///    put a fabricated reading into a log line and a metric.
/// 2. There is a `.notATypedStream(offset:)` case. The notes' five cases have nowhere to put
///    "these bytes are not this format", and that is a fact a bug report needs.
/// 3. `MessageBodySource` has five cases, not the two this task's table implied. A source of
///    `.textColumn` attached to a body that came from `payload_data` would be a lie the enum
///    could not express, and every consumer downstream reads that field to decide which column
///    to trust. The fifth case joined them on 2026-09-26 for the same reason — a voice note is
///    classified by `is_audio_message` when the stream refuses, and answering `.attributedBody`
///    there would have said the walk classified something it never read.
///
/// **`U+FFFC` is left in the text — unless it is the whole of it.** It is how a photo is marked,
/// and stripping it out of `U+FFFC a caption` makes a photo message look empty, which is the
/// exact failure this task exists to prevent. But when the marker's string field is **nothing
/// but the marker**, there is no caption to keep and no sentence to read: the balloon is an
/// attachment, and one object-replacement character is not the sender's words. That case is
/// `.notText`, and §"An effect is not an unreadable message" below is the measurement behind it.
///
/// ## Only the sender's own words leave this file (IM-17c, 2026-09-26)
///
/// A real `attributedBody` is **not text with a header**. Inside one 202-byte body measured on
/// this Mac: `NSAttributedString`, a nested `NSString` holding the sentence, and then a
/// `NSDictionary` keyed by `__kIMMessagePartAttributeName`. The 202-byte body is the *plain* end
/// of the range; the 298-byte and ~1140-byte bodies from the same capture carry a detected-entity
/// list, a link preview, a `com.apple.*` bundle id, and — in one of them — **`__kMSHSMessage`, a
/// third party's promotional payload carried as its own nested object with its own nested string, a
/// `$` value, a class range and a date range** (`TYPEDSTREAM-NOTES.md`, *The stream is an
/// attribute graph, not a string*). A Messages conversation with yourself is addressed to your own
/// phone number, so **a remote turn arrives wearing somebody else's marketing**, and the row it
/// arrives in is not a sentence.
///
/// So the decoder's guarantee is a **positive rule**, and it is one line long:
///
/// > **The answer is the characters of the string this body *is* — the first string-typed field
/// > of an object whose class chain says it is a text balloon or a string — and nothing else in
/// > the graph is read as text at all.**
///
/// **Why this point and not somewhere else.** It is the only place in the app where the blob
/// exists as bytes, and it is upstream of the classifier, the adapter, the memory gate, the
/// knowledge index, the model and the usage log — so one narrow return type here is upstream of
/// every consumer, where a scrubber on the way to the model, a filter in the usage log or a check
/// in the query seam is a separate place for somebody to remember. `UsageLog.sanitise` is
/// demonstrably the wrong one of those: it strips quoted content, addresses, URLs, paths and long
/// digit runs, and **a promotional offer is none of those — it is prose, and it survives every
/// rule in it**.
///
/// **Why the rule is not a denylist, and this is the load-bearing sentence.** A list of attribute
/// names to strip is a bet on the current macOS release: the measured graph held eight named
/// attributes plus a nested object whose shape nobody here knows, and an update adds a ninth. This
/// file never needed that list and still does not — there is nothing in it to add a name to. The
/// only two sets of names in this decoder are *recognitions* (`MessagesSchemaVersion.supported`,
/// `stringClasses`, `textBalloons`), which say **what a message body is**, and a reader that
/// stopped recognising it would refuse the body rather than misread it.
///
/// **A search is the hole, and closing it is what changed.** The walk this file used to run
/// descended into nested objects looking for the first string it could justify, and carried on
/// past a nested object that held none. That is a *search*, and a search over a graph that carries
/// a third party's nested object can land **on** that nested object: the offer, read as the
/// message. The walk is now anchored — one object, one field, one string — and everything else in
/// the stream is left unread. `archiver_a_foreign_payload_is_never_the_message` is the case that
/// pins it, and it is red on the old walk.
///
/// **What the count is, and what it is not.** `MessageBody.text` carries `discardedBytes`: the
/// number of bytes of the body the walk did **not** read, which on the attested 202-byte real body
/// is 101 of 202. It is a **volume about the format**, not about anybody's message, and it is the
/// only number this file adds. It is deliberately *not* a list of the names that were passed over
/// (a name is exactly the bet above) and *not* a count of attributes: counting attributes
/// accurately needs a grammar-aware skipper over the attribute runs, this decoder deliberately does
/// not model that grammar, and the tail's very first frame on the real body is a type tag the
/// reader does not name — guessing its width is the desynchronisation `TYPEDSTREAM-NOTES.md` §1.4
/// warns about. So the count is a **lower bound on what was discarded, in the one unit that is
/// exact**, and a macOS that starts attaching more graph makes it grow. `discardedBytes == 0` on a
/// body that measurably carries a nested object would mean the walk had read everything, which is
/// the one thing this guarantee says it never does.
enum MessagesDecoder {
    /// The largest `attributedBody` this will read at all, and over it is a refusal rather
    /// than a truncation.
    ///
    /// A megabyte of body text is a book; every real message is orders of magnitude below it.
    /// The cap exists so a corrupt length in somebody's live `chat.db` is an answer in
    /// microseconds instead of an allocation on the read path.
    static let maxBodyBytes = 1 << 20

    /// How deep the walk into nested objects goes. **Exactly two**, and that is now a property
    /// of the walk rather than a bound on it (IM-17c): a text balloon and the one string field
    /// inside it. It stays as a named constant because a reader that can be asked "how far does
    /// this go" should answer with data rather than with a number somebody remembers.
    static let maxObjectDepth = 2

    /// Shared strings one stream may register. A real body registers a handful (the class
    /// names, the type tags, the C strings); this is a bound on a blob that is not a stream.
    static let maxSharedStrings = 4_096
}

// MARK: - The envelope

/// The normalised record of one message, and the **only** thing that crosses out of the
/// database layer.
///
/// Named here and not inside `MessagesDecoder` because two files already say so: the roadmap
/// glossary calls it `IMessageEnvelope`, and `MessagesQueries`' header says *"Raw SQLite rows
/// stop here. What reaches the agent layer is IM-05's `IMessageEnvelope`."* A type whose name
/// is quoted in another file's contract does not get renamed by whoever writes it.
///
/// The chat a message belongs to is not here on purpose: it is the *query's* answer (a row can
/// be in two chats), and IM-06 knows which chat it asked about. What is here is the row's own
/// identity plus the decoded body, so a watcher can order by `rowID`, de-duplicate by `guid`,
/// and never has to hand a raw `MessageRow` to the agent layer.
struct IMessageEnvelope: Equatable, Sendable {
    /// `message.ROWID` — the watermark, and opaque.
    var rowID: Int64 = 0
    /// `message.guid`.
    var guid: String = ""
    /// `message.date`, nanoseconds since 2001-01-01.
    var date: Int64?
    /// `message.is_from_me`. **A column, not a direction** — IM-08 turns it into one, and
    /// which way it runs is IM-01's answer.
    var isFromMe: Bool = false
    /// `message.service` — `iMessage` or `SMS`.
    var service: String?
    /// The one stored fact about the body.
    var body: MessageBody
    /// Which column answered.
    var source: MessageBodySource

    /// The message text, or nil when this Mac could not read one.
    ///
    /// A `switch` and not a stored field, which is what makes `.unreadable` unable to
    /// become `""`: the enum has no empty-string representation and there is no code path
    /// that writes one. Downstream, `text != nil` is a claim the type system backs.
    var text: String? {
        switch body {
        case .text(let value, _): value
        case .unreadable, .notText, .absent: nil
        }
    }

    /// How much of the body the walk did not read — a volume about the *format*, never about
    /// the message. See `MessageBody.text`'s comment and the file header's IM-17c section.
    ///
    /// **Not zero for every non-`.text` body, and the reason is a measurement rather than a
    /// preference.** A refusal is a whole body the walk did not enter, so it carries no partial
    /// read; an *absent* row has no body at all. A **`.notText` body is the third thing**, and it
    /// is the largest of the three: the effect rows measured on 2026-09-26 are 314 bytes of which
    /// the walk read 77, so **237 bytes** of a third party's attribute graph were passed over
    /// unread — and on a body whose whole content is "there is nothing here to read", that is the
    /// number that says the walk stopped rather than wandered. An earlier version answered `0` for
    /// every non-`.text` body on the reasoning that "a body with no sender's words has nothing to
    /// have passed anything over"; the 314-byte effect disproves the reasoning — it has nothing to
    /// *read* and 237 bytes to pass over — and a `0` there would have been the one value that says
    /// the walk had read the whole body.
    ///
    /// **The one route that reports the whole body is the voice-note column, and that is a
    /// measurement rather than a shortcut.** When `is_audio_message` classifies a row the walk had
    /// refused, the walk read none of it, so "the bytes of this body that no caller can see as the
    /// sender's words" is *every* byte of it — 2 of 2 on the corpus row, and whatever a real
    /// voice note turns out to be. A count *smaller* than the body there would say the walk had
    /// read part of a body with no words in it, which is the failure this whole guarantee is
    /// about. The row with no body column is the other `0`, and there it is honest: there is
    /// nothing to have passed over.
    var discardedBytes: Int {
        switch body {
        case .text(_, let discarded): discarded
        case .notText(_, let discarded): discarded
        case .unreadable, .absent: 0
        }
    }

    /// Why the text is there, or why it is not. Derived from `body`, never stored, so the
    /// two cannot disagree — and every consumer has to say what it does with a body it
    /// could not read, which is the same enforcement as `OutputToken` making "no backend
    /// independently decides to speak" a compile error.
    var decodeState: MessageDecodeState {
        switch body {
        case .text: .decoded
        case .unreadable(let reason): .unreadable(reason: reason)
        case .notText(let bundleID, _): .notText(bundleID: bundleID)
        case .absent: .absent
        }
    }
}

extension MessagesDecoder {
    /// The normaliser. One row in, one envelope out, and every decision in one place.
    ///
    /// The precedence is the roadmap's, and the order is load-bearing rather than incidental:
    ///
    /// 1. **`text` present and non-empty wins.** A hybrid balloon carries both columns and the
    ///    cheap one is the right answer; a stream parse is work we do not need to do.
    /// 2. **`attributedBody` next.** For an iMessage this is the body, and for a photo or a
    ///    voice note it is the marker (`U+FFFC`) that says so — which is why the non-text
    ///    check is *third* and not first. A photo message carries `payload_data` too, so
    ///    checking `payload_data` before the blob would turn every photo into a refusal and
    ///    throw away the caption.
    /// 3. **`payload_data` + `balloon_bundle_id` next.** That pair is a non-text balloon: a
    ///    tapback, an app extension's message. The bundle id survives into the value, so the
    ///    agent layer can say what arrived. **This is one of three routes to `.notText`, not the
    ///    only one** — the roadmap's table used to say it was the only one, and 2026-09-26's
    ///    measurement is four effect rows with *both* columns NULL. An effect is classified by
    ///    the walk; a voice note is classified by `is_audio_message` when the walk has nothing
    ///    to say. See `body(fromAttributedBody:)` and the two sections below.
    /// 4. **`is_audio_message` last**, and only when nothing above produced an answer. A voice
    ///    note is a balloon with no words in it, so it is `.notText`; and it is a column rather
    ///    than a guess, which is what makes the answer possible on a row whose `attributedBody`
    ///    refuses. It cannot outrank a sentence, because a caption is the sender's words.
    /// 5. **Neither body column** is `.absent`, which is an ordinary row — an SMS whose
    ///    `attributedBody` is genuinely NULL — and not an error.
    ///
    /// An **empty** `text` falls through rather than answering: `""` is not a message, and
    /// treating an empty column as text is how a decoder ends up claiming a body it did not
    /// read. A row with an empty `text` and no blob is `.absent`, which is the honest name for
    /// "there is no body here to read" — unless the database says the row is audio, and then
    /// there is a third answer again.
    static func envelope(for row: MessageRow) -> IMessageEnvelope {
        let body: MessageBody
        let source: MessageBodySource
        if let text = row.text, !text.isEmpty {
            // The column *is* the sender's words, so there is no walk and nothing passed over.
            // A link preview or a nested payload lives in the stream, not here, which is also
            // why this path is the safe one to take first.
            body = .text(text, discardedBytes: 0)
            source = .textColumn
        } else if let blob = row.attributedBody {
            let walked = MessagesDecoder.body(fromAttributedBody: blob, balloonBundleID: row.balloonBundleID)
            if walked.deliveredNothing, row.isAudioMessage == true {
                // The column's turn, and the last turn there is. `discardedBytes` is the whole
                // body rather than a part of it, because the walk read none of it: the point of
                // the number is "no caller can see any of this body as the sender's words", and
                // the whole body is the honest answer when nothing was read.
                body = .notText(bundleID: MessagesDecoder.namedBalloon(row.balloonBundleID),
                                discardedBytes: blob.count)
                source = .isAudioMessage
            } else {
                body = walked
                source = .attributedBody
            }
        } else if row.payloadData != nil, let bundleID = MessagesDecoder.namedBalloon(row.balloonBundleID) {
            body = .notText(bundleID: bundleID, discardedBytes: 0)
            source = .payloadData
        } else if row.isAudioMessage == true {
            // No body column and no walk: there is nothing to have passed over, so the count is
            // 0 here and only here. The classification is the same one.
            body = .notText(bundleID: MessagesDecoder.namedBalloon(row.balloonBundleID),
                            discardedBytes: 0)
            source = .isAudioMessage
        } else {
            body = .absent
            source = .noColumn
        }
        return IMessageEnvelope(rowID: row.rowID,
                        guid: row.guid,
                        date: row.date,
                        isFromMe: row.isFromMe,
                        service: row.service,
                        body: body,
                        source: source)
    }

    /// `message.balloon_bundle_id`, or `nil` when nothing named this balloon.
    ///
    /// One rule for all three routes to `.notText`, and `nil` rather than `""` for the same
    /// reason `IMessageEnvelope.text` has no empty case: **an absent name and an empty one are
    /// different facts and only the first is true.** A NULL column, a zero-length column and a
    /// column this database does not have all mean nothing named it.
    static func namedBalloon(_ bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return bundleID
    }

    /// One `attributedBody` blob → `.text`, `.notText` or `.unreadable(reason:)`.
    ///
    /// Never `""` and never a throw, on purpose. The failure is a value so the caller can say
    /// something about it, and the reason carries a version byte and an offset — never a byte
    /// of the body — so it can go to the log and to the canary metric without carrying anybody's
    /// message with it.
    ///
    /// `balloonBundleID` is the row's `message.balloon_bundle_id`, passed in rather than read
    /// from the stream. It is `nil` on the measured effect rows and it is the only honest source
    /// for the id: the walk stops at the sender's words by design, so it has not read the
    /// attribute graph, and an id read out of the discarded region is a third party's value
    /// promoted into a state a caller can say out loud.
    static func body(fromAttributedBody blob: Data, balloonBundleID: String? = nil) -> MessageBody {
        guard blob.count <= maxBodyBytes else {
            return .unreadable(reason: .tooLarge(bytes: blob.count))
        }
        var reader = TypedStreamReader(blob)
        do {
            let version = try reader.readHeader()
            guard MessagesSchemaVersion.supported.contains(version) else {
                return .unreadable(reason: .unsupportedStreamVersion(found: version.streamerVersion,
                                                                    system: version.systemVersion))
            }
            // The positive rule, in the one place that owns it: the sender's own words and
            // nothing else. See the file header's IM-17c section for why it is here and not in
            // a scrubber three layers up.
            let decoded = try reader.senderText(of: blob)
            let discarded = decoded.discardedBytes
            let bundleID = namedBalloon(balloonBundleID)
            // **The attachment marker, when it is the whole of the body.** A balloon whose one
            // string is a single object-replacement character is an attachment: there is no
            // sentence in it to read, so it is `.notText` rather than a sentence. Measured on
            // the 314-byte effect rows — see "An effect is not an unreadable message" below.
            guard !decoded.isAttachmentOnly else {
                return .notText(bundleID: bundleID, discardedBytes: discarded)
            }
            // A stream that parses and holds a zero-length string is a body with no text in it,
            // not a body we could not read. Answering `.text("")` would put the one value this
            // whole task exists to keep out of the pipeline into it, so the invariant below
            // holds instead: **`text` is nil or non-empty, whichever column answered.**
            return decoded.text.isEmpty ? .absent : .text(decoded.text, discardedBytes: discarded)
        } catch let failure as MessageDecodeFailure {
            return .unreadable(reason: failure)
        } catch {
            return .unreadable(reason: .structureUnreadable(offset: reader.offset))
        }
    }
}

// MARK: - An effect is not an unreadable message

// Measured on this Mac, 2026-09-26, on four rows the owner captured by sending an effect to
// their own conversation from their phone. **These four rows disprove the roadmap's rule for
// `effect-bubble-classification`, and the answer is written here rather than left to the next
// reader.**
//
// ## What the 314 bytes are
//
//     04 0b "streamtyped" 1000            header, streamer 4 / system 1000
//     @  NSAttributedString(0)            the root, and it is an ordinary text balloon
//          NSObject(0)                    — the identical chain a 189-byte sentence carries
//     @  NSString(1) → NSObject(ref)      the balloon's first field
//     +  03  ef bf bc                    **U+FFFC, and it is the entire string**
//     86                                 end of object — the walk stops *before* this byte, at 77
//     …  237 bytes unread                 the attribute graph, from that same byte 77 to 313
//
// So: **the chain does not name the effect.** `NSAttributedString` → `NSObject` is the same two
// classes, in the same order, with the same versions, as the row on the same Mac that carries
// `Loved an image`. Matching the chain, which is the thing `TYPEDSTREAM-NOTES.md` says survives a
// format change, therefore tells you *nothing* about this row. **The only thing that says what
// this body is, is the three bytes the walk read.**
//
// ## Is there a bundle or balloon id in the stream? No.
//
// The 237 unread bytes hold a class name (`NSDictionary`), three attribute names, an
// `NSNumber`/`NSValue` pair and one id-shaped value: a 36-character UUID under
// `__kIMFileTransferGUIDAttributeName`, and **a different one in each of the four rows**. That is
// a per-message file-transfer id, not an app identity — the same message in the same thread four
// times produces four different ones, which is the opposite of a bundle id. There is no `com.`
// substring and no occurrence of "bundle" anywhere in the 314 bytes, and `balloon_bundle_id` is
// NULL on all four rows.
//
// **So the classifier takes the id from the column, and only from the column.** `.notText`'s
// bundle id is optional for the first time because a real row has none, and the alternative —
// inventing one, or reading the transfer GUID out of the discarded region — would put a claim in
// front of a person that the database does not support.
//
// ## Which state, and why not the other two
//
// - **Not text.** The one object-replacement character is Apple's marker for "there is an
//   attachment here", not the sender's sentence. Answering `.text("\u{FFFC}")` hands a model a
//   character the user never typed and calls it the user's words.
// - **Not `.unreadable`.** Nothing failed. The header was in the supported set, the chain parsed,
//   the first field's string was read by its declared length. `.unreadable(reason:)` means *this
//   Mac could not read a body that has words in it*, and using it for an ordinary effect is
//   crying wolf: the roadmap's own IM-05 spec says *"a decoder that reports it as unreadable
//   would be crying wolf on half the messages"*, and a person told "I couldn't read that" every
//   time they send a reaction stops trusting the feature and can no longer see the real
//   breakage — a macOS update changing the format.
// - **`.notText`, whose id is `nil`.** "Not a text balloon: a tapback, an effect, an app
//   extension's message." An effect *is* that, and it is the case the enum has always named.
//   The spelling was wrong, not the state: it required an id this row cannot supply.
//
// ## The rule, and what it deliberately does not do
//
// The first string field is compared for **equality** with the marker, not for containment.
// `U+FFFC a caption` is a photo with a caption, the caption is the sender's, and it stays text
// (`archiver_oracle_attachment_marker_survives` pins that half). Only a string that is *nothing
// but* the marker is an attachment, because only then is there no sentence behind it.
//
// **A fifth case was considered and is not wanted.** `.notText` already means this; what the
// measurement corrected is its payload — an id that may be absent — and its count. A new case
// would be a second spelling of a state the enum already has, and the type-level enforcement
// that matters here (`Text` has no `""`, `.text` cannot carry a second string) is untouched by it.

// MARK: A voice note is not an unreadable message

// IM-05d, 2026-09-26. **The same question as the effect, one row over, and the two answers are
// on different columns.** The roadmap said a voice note is `.notText` and named the signal it
// expected: `message.is_audio_message`. What it did not know is which of two signals a *real*
// voice note actually carries, and the two candidates are on opposite sides of the walk:
//
// | candidate | what it can answer | what it cannot |
// |---|---|---|
// | **`is_audio_message`**, a column | a row whose body refuses, and a row with no body at all | nothing about what the body holds — it says what the row *is*, never what the bytes say |
// | **the class chain / the three bytes**, the walk | a readable body that declares itself (`U+FFFC`), and a caption beside it | a body it cannot read, which is the case a voice note on this corpus is |
//
// ## Which one carries it, measured: on the corpus row, only the column
//
// `Tests/Fixtures/chatdb`'s `voice-note` case has carried `is_audio_message=1` since IM-04
// built it, and its `attributedBody` is the two-byte `X'0001'` sentinel. **There is no class
// chain on that row to read**: the walk stops at the header and refuses, so a decoder that knew
// nothing but the walk could not tell it from a text body that failed to decode — which is
// exactly what IM-05 recorded when it printed `IMESSAGE_DECODE_BLOCKED: voice-note-as-not-text`
// and classified the row as a refusal. That is the *only* half of the question that could be
// answered without the owner's phone, and the column answers it.
//
// ## The half that is not, and is named rather than guessed
//
// **A real voice note's `attributedBody` has not been captured.** Every attachment measured on
// this Mac so far — four effect rows — is a text balloon whose whole string is `U+FFFC`, and
// **if a voice note is one of those the walk classifies it and the column is redundant for that
// row.** That is a prediction, not a measurement, and the roadmap's rule about oracle cases
// applies with full force: closing the blocked line by asking `NSArchiver` to write a plausible
// body would assert a fact about Messages that nothing here has read. The assertion stays
// blocked on the capture and says so by name.
//
// **So the code answers both, and they are complementary by construction rather than by
// accident.** The walk goes first, so a caption is the sender's words and the column never
// overrules a sentence; the column goes last, so it only ever answers on a body the walk had
// nothing to say about. Whichever of the two a real row carries, the row is `.notText` — and
// if a future macOS carries neither, the row is a refusal, which is the honest answer and the
// one the blocked line is waiting to be able to rule out.
//
// ## Why not the other two states
//
// - **Not text**, for the same reason an effect is not: an audio attachment has no words in it,
//   and `.text` of a caption-free marker is a character the sender never typed.
// - **Not `.unreadable`**, on the same grounds the effect case set out, and this row is the
//   *stronger* example of it: the body here is not a body at all in any sense this Mac can
//   read, so crying "I could not read that" once per voice note is crying wolf on ordinary use.
//   A person who is told that every time they send a recording stops believing the sentence
//   that matters.
// - **`.notText` with no id**, and the type is what makes that expressible. `bundleID` is
//   `String?` because a measured effect row had nothing to name it, and a voice note is the
//   same answer to a second question: `balloon_bundle_id` is NULL on a voice note the same way
//   it is on an effect, and the classification is not required to invent an app to exist.
//
// ## What the walk is not asked to do
//
// **The audio route reads no byte of the body.** That is why `discardedBytes` there is the
// *whole* body rather than a part of it: the count means "no caller can see any of this body as
// the sender's words", and when nothing was read that is every byte of it. A count of 0 would be
// the one value that says the walk had read a body with nothing in it, which is the same
// mistake IM-05c found on the effect rows and the reason that case asserts `> blob.count / 2`.
// A body with **no** body column at all is the one place the count is honestly 0, because there
// is nothing there to have passed over — and it is the only place.

// MARK: - The version gate

/// The 16 bytes every little-endian typedstream begins with, read as a pair.
///
/// **The gate is a `Set` and not a comparison.** A `Set` is a lookup, so the self-test can
/// state the *policy* — only these headers are decoded — and a future macOS that needs a
/// second entry is one line of data with a test that names it, rather than an `if` somebody
/// edits in a hurry. The header is the whole of what this decoder knows about the version, and
/// it is the one thing worth refusing on: a stream whose header is not one we have read is a
/// stream whose layout we do not know, and reading it anyway is how a plausible-looking
/// sentence comes out of a sentence that was never written.
struct MessagesSchemaVersion: Equatable, Hashable, Sendable {
    /// Offset 0: the streamer version, which `file(1)` prints as "version 4".
    var streamerVersion: UInt8
    /// The system version, a little-endian integer that follows the 13-byte header. Read as an
    /// integer rather than as the `u16` at offsets 14–15, because that is only where it lands
    /// when the head byte before it is `0x81`; a one-byte system version would sit at 13 and a
    /// four-byte one at 14–17. `1000` for every macOS version anyone has looked at.
    var systemVersion: UInt16

    init(streamerVersion: UInt8, systemVersion: UInt16) {
        self.streamerVersion = streamerVersion
        self.systemVersion = systemVersion
    }

    /// The headers this decoder reads, and the whole of its version policy.
    ///
    /// **Measured 2026-09-25 on macOS 27.0**: `NSArchiver` still writes
    /// `04 · "streamtyped" · 1000`. Not measured: what Messages writes, which needs IM-01.
    static let supported: Set<MessagesSchemaVersion> = [
        MessagesSchemaVersion(streamerVersion: 0x04, systemVersion: 1000)
    ]

    /// The signature at offsets 2–12. Little-endian is `"streamtyped"`, big-endian is
    /// `"typedstream"`; the big-endian spelling is NeXTSTEP's and is refused rather than
    /// decoded, because a reader that guessed the byte order would be guessing at every
    /// integer in the stream.
    static let signature = "streamtyped"
    static let signatureOffset = 2
}

// MARK: - The three value types

/// What a message's body turned out to be. The only stored fact about a body, and the reason
/// `text` and `decodeState` are derived rather than written twice.
///
/// **One string, and one number. That is the whole of it (IM-17c).** There is no bag, no
/// dictionary and no array of attribute names, because a body carries a third party's payload
/// (see the file header) and the only place that payload must not reach is *here*. A new case
/// with a second string in it is a compile error at every `case .text` in the tree, which is
/// the enforcement; `archiver_a_foreign_payload_is_never_the_message` and
/// `archiver_a_link_preview_does_not_change_the_message` are the assertions.
///
/// **The one string a non-text balloon may carry is an id, and it is optional (IM-05c).** It is
/// optional because a measured effect row has none: `balloon_bundle_id` is NULL on all four of
/// the 2026-09-26 rows and the stream holds no bundle id either (see "An effect is not an
/// unreadable message" above). The invariant that buys is the one the measurement forced: **a
/// non-text balloon can no longer be required to name an app**, so the classifier cannot invent
/// an id to satisfy the type, and a caller cannot be written to print an identity the database
/// does not have. Before this, the only two ways to construct the case on such a row were to
/// fabricate a bundle id or to pass `""`, and both are lies a person would be shown.
enum MessageBody: Equatable, Sendable {
    /// A body somebody can read. From `text`, or from a decoded stream.
    ///
    /// `discardedBytes` is how much of the body the walk did **not** read — the attribute
    /// graph, a detected-entity list, a link preview, a nested object that is not the
    /// sender's. It travels *with* the string rather than beside it so that a value carrying
    /// the sender's words and a value carrying a volume of somebody else's payload are one
    /// thing a caller has to hold, and so the number cannot be filled in by a caller that
    /// never ran the walk.
    case text(String, discardedBytes: Int)
    /// A body this Mac could not read. **Never the empty string** — there is no way to spell
    /// that here, which is the point.
    case unreadable(reason: MessageDecodeFailure)
    /// Not a text balloon: a tapback, an effect, an app extension's message — a balloon that
    /// carries no sentence, as against one this Mac could not read.
    ///
    /// `bundleID` is what the row names, and `nil` means **nothing named it**: the column was
    /// NULL and the stream carries no id, which is the measured state of a real effect. It is
    /// `nil`, never `""`, for the same reason `text` has no empty case — an absent name and an
    /// empty one are different facts and only the first is true here.
    ///
    /// `discardedBytes` means exactly what it does on `.text`: bytes of this body the walk did
    /// not read. It is **not** zero for this case and that is the point — a balloon with no
    /// words in it is where the unread payload is largest (237 of 314 bytes on the measured
    /// effect), so the number is what says the walk stopped instead of reading a third party's
    /// attribute graph looking for a sentence.
    case notText(bundleID: String?, discardedBytes: Int)
    /// No body column on this row at all — an SMS, or a row older than iMessage. An ordinary
    /// answer, distinct from a refusal.
    case absent
}

/// Why a body could not be read. A value, not an exception: `NSUnarchiver` signals failure by
/// raising, and a raised `NSException` cannot be caught in Swift, so it would be a process
/// exit rather than a sentence.
enum MessageDecodeFailure: Error, Equatable, Sendable {
    /// The header is not one of `MessagesSchemaVersion.supported`.
    ///
    /// `system` is optional because it is honestly optional: the streamer version is at offset
    /// 0 and readable from a two-byte blob, while the system version needs the whole header. A
    /// refusal that named a system version it could not read would be a fabricated fact in a
    /// log line and in a canary metric.
    case unsupportedStreamVersion(found: UInt8, system: UInt16?)
    /// The bytes are not a little-endian typedstream — no signature where one belongs.
    case notATypedStream(offset: Int)
    /// The cursor ran out of bytes, at the offset it ran out at.
    case truncated(offset: Int)
    /// A tag, a reference or a type this reader does not model, at an offset. **Never
    /// repaired**: a reader that steps over what it does not understand and carries on is how
    /// a length-driven parse becomes a printable-run scan.
    case structureUnreadable(offset: Int)
    /// The stream parsed, and what it holds is not a string.
    case notAString(offset: Int)
    /// Over `MessagesDecoder.maxBodyBytes`.
    case tooLarge(bytes: Int)

    /// Log- and metric-safe by construction: a version byte, a count and an offset. No byte of
    /// a message body, no URL, no path — so this can be counted and reported without carrying
    /// anybody's conversation with it. The version number is a fact for a bug report; it is
    /// never a fact for a person (see `PersonaCareEval`).
    var description: String {
        switch self {
        case .unsupportedStreamVersion(let found, let system):
            let seen = system.map { String($0) } ?? "absent"
            return "unsupported stream version — streamer 0x\(String(found, radix: 16)), system \(seen)"
        case .notATypedStream(let offset):
            return "not a typedstream — no signature at offset \(offset)"
        case .truncated(let offset):
            return "truncated — ran out of bytes at offset \(offset)"
        case .structureUnreadable(let offset):
            return "structure unreadable at offset \(offset)"
        case .notAString(let offset):
            return "no string in the stream — read to offset \(offset)"
        case .tooLarge(let bytes):
            return "too large — \(bytes) bytes"
        }
    }
}

extension MessageBody {
    /// Whether the walk produced **nothing a caller could show** — a refusal, or a body with
    /// nothing in it.
    ///
    /// This is the question `is_audio_message` gets asked, and it is asked here rather than in
    /// `envelope(for:)` so the answer cannot be spelled two ways. **`.notText` is deliberately
    /// not one of these**: the walk *read* that one and it is already the right answer, so a
    /// row that also says it is audio must not have its own answer written over the walk's.
    /// `.text` is excluded for the same reason and more obviously — a caption is the sender's
    /// words and a column does not outrank a sentence.
    var deliveredNothing: Bool {
        switch self {
        case .text, .notText: false
        case .unreadable, .absent: true
        }
    }
}

/// What a caller can say about a body, without being handed the reason's innards.
///
/// **The name and nothing else, deliberately.** `.notText` carries the id — because naming what
/// arrived is what the state is *for* — and not the count, because the count has its own accessor
/// (`IMessageEnvelope.discardedBytes`) and one number with one meaning is worth more than a second
/// copy of it that could disagree.
enum MessageDecodeState: Equatable, Sendable {
    case decoded
    case unreadable(reason: MessageDecodeFailure)
    /// A balloon that carries no sentence. The id is `nil` when nothing named what arrived, which
    /// is the measured state of a real effect — see "An effect is not an unreadable message".
    case notText(bundleID: String?)
    /// No body on this row. Not an error, and not an empty message.
    case absent
}

/// Which column produced the body. `.noColumn` is the honest answer for a row that had
/// nothing to read; a source that lied would be worse than no source at all.
///
/// **A `.notText` body can come from any of three columns**, and this is what says which:
/// `.payloadData` is the tapback route (`payload_data` + `balloon_bundle_id`, no stream to
/// read), `.attributedBody` is the effect route (a stream the walk read, which declared
/// itself to hold no words) and `.isAudioMessage` is the voice-note route (a stream the walk
/// could not read, or none, on a row the database says is audio). One state, three columns,
/// and the accessor that tells them apart is data rather than a second case.
///
/// **The fifth case is why this field exists at all.** An earlier version answered
/// `.attributedBody` for a voice note, which was a lie in the direction that matters: the
/// stream said nothing whatever about that row, and `envelope(for:)`'s audio rule is the only
/// thing that classified it. A caller asking "did the walk classify this or did a column?"
/// was getting a wrong answer, and the wrong answer was the reassuring one.
enum MessageBodySource: Equatable, Sendable {
    /// `message.text`.
    case textColumn
    /// `message.attributedBody`, decoded — or read far enough to say it holds no words.
    case attributedBody
    /// `message.payload_data` + `balloon_bundle_id` — a non-text balloon named by its column.
    case payloadData
    /// `message.is_audio_message` on a row the walk had nothing to say about.
    case isAudioMessage
    /// Nothing answered.
    case noColumn
}

// MARK: - The reader

/// A cursor over one typedstream, reading only what a message body needs.
///
/// **Length-driven or refuse, never a scan.** The roadmap forbids finding the first printable
/// run, and it is right for a stronger reason than tidiness: a scan returns a *prefix* of the
/// text with no error at all, and a truncated sentence is a sentence a person will act on.
/// Every string here is read by its declared length, so this reader produces the whole string
/// or refuses.
///
/// **Why it can afford not to model the type grammar.** The text is the first field of a nested
/// string object, and this reader stops as soon as it has it — so every value it has to
/// understand is one of three: an object (`@`, open it), a string (`+` or `*`, take it), or a
/// refusal. It never has to step over a value whose width it does not know, because it never
/// reaches one. That is the whole of `TYPEDSTREAM-NOTES.md` §5.3's "only the string is wanted,
/// so only the string is modelled" — and it is why a *different* root shape is a refusal rather
/// than a guess.
///
/// **Stopping is also the privacy guarantee (IM-17c).** The attribute graph behind the text —
/// the detected entities, the link preview, the bundle id, the nested object that is somebody
/// else's — is never *read*, so there is nothing downstream that could hold it. A reader that
/// walked the tail in order to count or inspect it would be modelling the grammar after all, and
/// the tail's first frame on the real 202-byte body is a type tag this decoder does not name
/// (`iI`, immediately after the text's end-of-object marker). Guessing that one's width is the
/// desynchronisation `TYPEDSTREAM-NOTES.md` §1.4 warns about, which is why the count this
/// reader reports is unread **bytes** and not a list of names.
///
/// **Every loop is bounded by the bytes remaining** and every read is bounds-checked. A parser
/// that can fail to advance is a hang inside the message read path, and a hang there is a
/// silent stop rather than an error.
private struct TypedStreamReader {
    private let bytes: [UInt8]
    /// How far the cursor has read. Read by `MessagesDecoder` when it has to report an offset
    /// the reader itself could not produce.
    private(set) var offset = 0
    private var shared: [[UInt8]] = []

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    // Tags and heads
    //
    // A head byte is one of four things and the byte alone says which: a tag (0x80–0x8F), a
    // literal integer (0x00–0x7F), a multi-byte-integer marker (0x81/0x82), or a reference
    // number (0x92 and up). TYPEDSTREAM-NOTES.md's table lists `0x87` as an eight-byte integer
    // marker; it is not — 0x87–0x91 are reserved tags that a real stream never writes, and
    // treating them as integers would read a length out of nothing. Refused here.

    private enum Tag {
        static let integer2: UInt8 = 0x81
        static let integer4: UInt8 = 0x82
        static let new_: UInt8 = 0x84
        static let nil_: UInt8 = 0x85
        static let endOfObject: UInt8 = 0x86
        /// The first reference number. Everything at or above this byte is a reference into the
        /// shared tables, which is why a literal integer can never be 0x92 or above.
        static let firstReference: UInt8 = 0x92
    }

    /// The signed value of a head byte, and the arithmetic every reference number goes through.
    private static func signed(_ byte: UInt8) -> Int { Int(Int8(bitPattern: byte)) }

    private var remaining: Int { bytes.count - offset }

    private mutating func take() throws -> UInt8 {
        guard offset < bytes.count else { throw MessageDecodeFailure.truncated(offset: offset) }
        defer { offset += 1 }
        return bytes[offset]
    }

    // MARK: Header

    /// The version pair, read the way the format actually lays it out rather than the way a
    /// 16-byte dump suggests: streamer version, signature length, signature, then the system
    /// version as a typedstream integer whose own width the head byte chooses.
    ///
    /// **The streamer version is checked before the signature, and that order is the point.**
    /// The corpus's `X'0001'` sentinel is two bytes, so the version byte is there and the
    /// signature is not; a signature check first would answer "these bytes are not a
    /// typedstream" and lose the fact that the version is the thing that is wrong. The gate is
    /// also a `Set` membership test, so the second half of the pair is checked the same way
    /// against the same data in `MessagesDecoder.body(fromAttributedBody:)`.
    mutating func readHeader() throws -> MessagesSchemaVersion {
        let streamerVersion = try take()
        guard MessagesSchemaVersion.supported.contains(where: { $0.streamerVersion == streamerVersion }) else {
            throw MessageDecodeFailure.unsupportedStreamVersion(found: streamerVersion, system: nil)
        }
        let signatureLength = try take()
        guard Int(signatureLength) == MessagesSchemaVersion.signature.utf8.count else {
            throw MessageDecodeFailure.notATypedStream(offset: MessagesSchemaVersion.signatureOffset)
        }
        let signature = try readBytes(Int(signatureLength))
        guard String(decoding: signature, as: UTF8.self) == MessagesSchemaVersion.signature else {
            throw MessageDecodeFailure.notATypedStream(offset: MessagesSchemaVersion.signatureOffset)
        }
        let systemVersion = try readUnsignedInteger()
        return MessagesSchemaVersion(streamerVersion: streamerVersion,
                                     systemVersion: UInt16(truncatingIfNeeded: systemVersion))
    }

    // MARK: Integers

    /// A typedstream integer, read as unsigned. A one-byte value, or `0x81` + `u16`, or
    /// `0x82` + `u32`; anything else in the tag range is a tag where a number belongs.
    private mutating func readUnsignedInteger(head: UInt8? = nil) throws -> Int {
        let head = try head ?? take()
        if head < 0x80 { return Int(head) }
        switch head {
        case Tag.integer2:
            let value = try readFixedWidth(2)
            return Int(UInt16(value[0]) | UInt16(value[1]) << 8)
        case Tag.integer4:
            let value = try readFixedWidth(4)
            return Int(UInt32(value[0]) | UInt32(value[1]) << 8 | UInt32(value[2]) << 16 | UInt32(value[3]) << 24)
        default:
            throw MessageDecodeFailure.structureUnreadable(offset: offset)
        }
    }

    /// A typedstream integer, read as signed — class versions and range components.
    private mutating func readSignedInteger(head: UInt8? = nil) throws -> Int {
        let head = try head ?? take()
        if head < 0x80 { return TypedStreamReader.signed(head) }
        switch head {
        case Tag.integer2:
            let value = try readFixedWidth(2)
            let raw = UInt16(value[0]) | UInt16(value[1]) << 8
            return Int(Int16(bitPattern: raw))
        case Tag.integer4:
            let value = try readFixedWidth(4)
            var raw: UInt32 = 0
            for (index, byte) in value.enumerated() { raw |= UInt32(byte) << (8 * UInt32(index)) }
            return Int(Int32(bitPattern: raw))
        default:
            throw MessageDecodeFailure.structureUnreadable(offset: offset)
        }
    }

    private mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remaining else {
            throw MessageDecodeFailure.truncated(offset: offset)
        }
        let slice = Array(bytes[offset..<(offset + count)])
        offset += count
        return slice
    }

    private mutating func readFixedWidth(_ width: Int) throws -> [UInt8] {
        try readBytes(width)
    }

    // MARK: Strings

    /// A raw, unshared string: a length and that many bytes. This is what the message text is.
    private mutating func readUnsharedString(head: UInt8? = nil) throws -> [UInt8]? {
        let head = try head ?? take()
        if head == Tag.nil_ { return nil }
        let length = try readUnsignedInteger(head: head)
        return try readBytes(length)
    }

    /// A shared string: nil, a literal (which is registered for later reference), or a
    /// reference number into the table.
    ///
    /// One table serves class names, type-encoding tags, selectors and C strings, which is why
    /// a reference here is not necessarily a reference to another *string* — it is a reference
    /// to whatever was registered at that number, and the context says how to read it.
    private mutating func readSharedString(head: UInt8? = nil) throws -> [UInt8]? {
        let head = try head ?? take()
        if head == Tag.nil_ { return nil }
        if head == Tag.new_ {
            guard let literal = try readUnsharedString(), shared.count < MessagesDecoder.maxSharedStrings else {
                throw MessageDecodeFailure.structureUnreadable(offset: offset)
            }
            shared.append(literal)
            return literal
        }
        let index = try referenceIndex(head)
        guard index < shared.count else { throw MessageDecodeFailure.structureUnreadable(offset: offset) }
        return shared[index]
    }

    /// A C string (`char *`): nil, a literal shared string, or a reference. One level deeper
    /// than a `+` because a `*` is deduplicated and a `+` is not.
    private mutating func readCString(head: UInt8? = nil) throws -> [UInt8]? {
        let head = try head ?? take()
        if head == Tag.nil_ { return nil }
        if head == Tag.new_ { return try readSharedString() }
        return try readSharedString(head: head)
    }

    private mutating func referenceIndex(_ head: UInt8) throws -> Int {
        guard head >= Tag.firstReference else {
            throw MessageDecodeFailure.structureUnreadable(offset: offset)
        }
        return TypedStreamReader.signed(head) + 110
    }

    // MARK: The sender's own words

    /// The string this body **is**, and how much of the body the walk did not read.
    ///
    /// **This is the positive rule, and the whole of the privacy guarantee.** One object, one
    /// field, one string:
    ///
    /// | the root's class chain says | the walk reads | anything else |
    /// |---|---|---|
    /// | it is a **string** (`stringClasses`) | its first field, as characters | left unread |
    /// | it is a **text balloon** (`textBalloons`) | its first field's one string field | left unread |
    /// | neither | `notAString` | — |
    ///
    /// A nested object that is not a string is `notAString` too, **not** a place to keep
    /// looking. That is the whole difference from the search this replaced: the old walk
    /// descended into nested objects until it found a string it could justify, and a graph
    /// carrying a third party's payload can be searched *onto* that payload.
    ///
    /// **What the walk reads is the whole of the question, and the marker is part of what it
    /// reads.** An attachment balloon's one string is `U+FFFC` — three bytes and no sentence — and
    /// this method returns it as the string it is, with `isAttachmentOnly` answering the one
    /// question the classifier then has to ask. It is *not* filtered out here, because a body
    /// whose string is `U+FFFC a caption` is a photo with a caption and the caption is text.
    mutating func senderText(of blob: Data) throws -> DecodedText {
        // The root of a body is one type-prefixed object value, and its tag is `@`.
        guard let rootTag = try readSharedString(),
              MessagesDecoder.tagName(rootTag) == "@" else {
            throw MessageDecodeFailure.notAString(offset: offset)
        }
        let root = try openObject()
        let isString = root.contains(where: MessagesDecoder.stringClasses.contains)
        let isBalloon = root.contains(where: MessagesDecoder.textBalloons.contains)
        guard isString || isBalloon else {
            // An object that is not a text balloon is not a message body, whatever it holds.
            // `NSNumber`'s first field is its `objCType`, a `char *`, and reading it would
            // answer `q`.
            throw MessageDecodeFailure.notAString(offset: offset)
        }
        let text = isString ? try characters() : try characters(ofStringFieldOfBalloon: root, depth: 1)
        return DecodedText(text: text, discardedBytes: blob.count - offset)
    }

    /// Consume the `new` marker and read the class chain of the object the cursor is on.
    private mutating func openObject() throws -> [String] {
        guard try take() == Tag.new_ else {
            // A nil, or a reference to an object written earlier. Neither can be read as a
            // body: there is no first occurrence of a message's own text to point at, so a
            // reference here is a shape this decoder does not know.
            throw MessageDecodeFailure.structureUnreadable(offset: offset)
        }
        return try readClassChain()
    }

    /// The characters of a string object: its first field, read by its declared byte length.
    ///
    /// `+` is an unshared string (a length and that many bytes) and `*` is a shared C string
    /// (a reference into the table, one level deeper because a `*` is deduplicated and a `+`
    /// is not). Both are read by length, so a truncated one is a refusal and never a prefix.
    private mutating func characters() throws -> String {
        let head = try take()
        guard let tag = try readSharedString(head: head) else {
            throw MessageDecodeFailure.notAString(offset: offset)
        }
        let raw: [UInt8]?
        switch MessagesDecoder.tagName(tag) {
        case "+": raw = try readUnsharedString()
        case "*": raw = try readCString()
        default: throw MessageDecodeFailure.notAString(offset: offset)
        }
        guard let raw, let text = String(bytes: raw, encoding: .utf8) else {
            throw MessageDecodeFailure.notAString(offset: offset)
        }
        return text
    }

    /// The one string field of a text balloon: its first field, which has to *be* a string.
    ///
    /// The class chain is matched rather than the leaf name, which is what lets a private
    /// concrete subclass (`__NSCFString` and its relations) be recognised through the
    /// superclass that is in the stream — and it is also what keeps
    /// `NSMutableAttributedString`, which contains the word "String" and holds no text in its
    /// first field, from being mistaken for one.
    private mutating func characters(ofStringFieldOfBalloon balloon: [String], depth: Int) throws -> String {
        guard balloon.contains(where: MessagesDecoder.textBalloons.contains) else {
            throw MessageDecodeFailure.notAString(offset: offset)
        }
        guard let fieldTag = try readSharedString(), MessagesDecoder.tagName(fieldTag) == "@" else {
            throw MessageDecodeFailure.notAString(offset: offset)
        }
        // The one bound the walk still needs, and it is checked rather than assumed: the walk
        // reaches depth two on a real body and can go no further, so a blob that asks for a
        // third is refused instead of being read.
        guard depth < MessagesDecoder.maxObjectDepth else {
            throw MessageDecodeFailure.structureUnreadable(offset: offset)
        }
        let nested = try openObject()
        guard nested.contains(where: MessagesDecoder.stringClasses.contains) else {
            // **A nested object that is not a string is where the old walk used to keep
            // digging.** It is a refusal here, and the refusal is the guarantee.
            throw MessageDecodeFailure.notAString(offset: offset)
        }
        return try characters()
    }

    /// The class chain of the object just opened: literal classes in order, each a name and a
    /// version, ending at a `nil` superclass or at a reference to a class written earlier.
    ///
    /// Bounded at 64: an object has a handful of ancestors, and a chain deeper than that is a
    /// blob that is not a message.
    private mutating func readClassChain() throws -> [String] {
        var names: [String] = []
        while names.count <= 64 {
            let head = try take()
            if head == Tag.nil_ { return names }
            if head == Tag.new_ {
                guard let name = try readSharedString(), !name.isEmpty else {
                    throw MessageDecodeFailure.structureUnreadable(offset: offset)
                }
                _ = try readSignedInteger()
                names.append(String(decoding: name, as: UTF8.self))
                continue
            }
            if head >= Tag.firstReference { return names }   // a class reference ends the chain
            throw MessageDecodeFailure.structureUnreadable(offset: offset)
        }
        throw MessageDecodeFailure.structureUnreadable(offset: offset)
    }
}

extension MessagesDecoder {
    /// The classes whose **first field is the text**, matched anywhere in a class chain.
    ///
    /// **Data, for the same reason `MessagesSchemaVersion.supported` is data**: what a macOS
    /// writes is a fact about macOS, and a reader that has to be edited to recognise a new
    /// private subclass is a reader that will be edited in a hurry. The chain is matched rather
    /// than the leaf, so `__NSCFString` is recognised by the `NSString` above it.
    static let stringClasses: Set<String> = [
        "NSString",
        "NSMutableString",
        "NSConcreteString"
    ]

    /// The classes that **are a message body**: an attributed string, whose first field is one
    /// string and whose second is the attribute graph this decoder does not read.
    ///
    /// **This is a recognition, not a removal list, and that distinction is the whole design
    /// (IM-17c).** It says *what a body is*, in the same way `stringClasses` says what a string
    /// is and `MessagesSchemaVersion.supported` says what a header is: a recognition a future
    /// macOS extends by one line. Nothing in this file names an attribute, and a macOS that
    /// attaches a ninth attribute, a tenth class or a nested object nobody has seen changes
    /// nothing here — the walk stops at the sentence and the rest of the body is never read.
    ///
    /// **Measured 2026-09-26 on Messages' own bytes**: the 202-byte self-message's root chain is
    /// `NSAttributedString` → `NSObject`, and the oracle's `NSMutableAttributedString` writes
    /// `NSMutableAttributedString` → `NSAttributedString` → `NSObject`. A private concrete
    /// subclass is recognised through its superclass, which is in the stream.
    static let textBalloons: Set<String> = [
        "NSAttributedString",
        "NSMutableAttributedString"
    ]

    /// A type-encoding tag as a name.
    ///
    /// One spelling of the comparison, because the walk compares tags in four places and a
    /// reader that guessed which bytes are a tag would be guessing at every integer in the
    /// stream. A tag this decoder does not model comes back as its own name, which no `case`
    /// below matches — so an unknown tag is a refusal rather than a step.
    static func tagName(_ tag: [UInt8]) -> String {
        String(decoding: tag, as: UTF8.self)
    }

    /// **`U+FFFC OBJECT REPLACEMENT CHARACTER`**, which is what iMessage writes in a body's one
    /// string when the balloon is an attachment rather than a sentence.
    ///
    /// **The exact scalar, compared for equality, and that is the whole rule.** Contained-in is
    /// the obvious wrong comparison and the roadmap's own `U+FFFC` handling is what it would
    /// break: a caption arrives in the same string, `U+FFFC a caption`, and the caption *is* the
    /// sender's words. So the marker is text whenever it has company and is an attachment when it
    /// is alone. Measured on this Mac, 2026-09-26, on the 314-byte effect rows: the field was
    /// three bytes and nothing else.
    static let attachmentMarker = "\u{FFFC}"

    /// Whether a decoded body is the attachment marker and **nothing else** — the one question
    /// `MessagesDecoder.body(fromAttributedBody:balloonBundleID:)` asks of a string it just read.
    ///
    /// Written as a `String` comparison rather than a scalar loop so that "the whole string" is
    /// checked by the equality itself, and so the question cannot become "starts with the
    /// marker" by an edit to the operator.
    static func isAttachmentOnly(_ text: String) -> Bool {
        text == attachmentMarker
    }
}

/// The decoder's answer: the string the body is, and the volume of the body it passed over.
///
/// **Two fields, both about the format.** `text` is the sender's own words and nothing else —
/// see the file header's IM-17c section — and `discardedBytes` is how much of the body the walk
/// did not read, which is a lower bound on the attribute graph, the detected entities, the link
/// preview and any nested object that came with the message.
struct DecodedText: Equatable, Sendable {
    /// Non-empty, or the decoder answered `.absent` instead. There is no way to spell `""` here.
    var text: String
    /// Bytes of the body the walk stopped short of. Zero only for a body that is nothing but
    /// the sentence.
    var discardedBytes: Int
    /// **That the body is the attachment marker and no sentence at all** — a fact about what was
    /// read, answered by the same equality every time, and a computed property so the question
    /// cannot be asked two ways and answered two ways.
    var isAttachmentOnly: Bool { MessagesDecoder.isAttachmentOnly(text) }
}
