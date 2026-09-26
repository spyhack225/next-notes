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
/// 3. `MessageBodySource` has four cases rather than two. A source of `.textColumn` attached
///    to a body that came from `payload_data` would be a lie the enum could not express.
///
/// **`U+FFFC` is left in the text.** It is how a photo is marked; stripping it makes a photo
/// message look empty, which is the exact failure this task exists to prevent.
enum MessagesDecoder {
    /// The largest `attributedBody` this will read at all, and over it is a refusal rather
    /// than a truncation.
    ///
    /// A megabyte of body text is a book; every real message is orders of magnitude below it.
    /// The cap exists so a corrupt length in somebody's live `chat.db` is an answer in
    /// microseconds instead of an allocation on the read path.
    static let maxBodyBytes = 1 << 20

    /// How deep the walk into nested objects goes. Measured depth for a message body is
    /// **two** (`NSMutableAttributedString` → `NSMutableString`); this is a bound on a
    /// malformed or hostile blob, not a shape we expect to reach.
    static let maxObjectDepth = 8

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
        case .text(let value): value
        case .unreadable, .notText, .absent: nil
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
        case .notText(let bundleID): .notText(bundleID: bundleID)
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
    /// 3. **`payload_data` + `balloon_bundle_id` last.** That pair is a non-text balloon: a
    ///    tapback, an effect, an app extension's message. The bundle id survives into the
    ///    value, so the agent layer can say what arrived.
    /// 4. **Neither body column** is `.absent`, which is an ordinary row — an SMS whose
    ///    `attributedBody` is genuinely NULL — and not an error.
    ///
    /// An **empty** `text` falls through rather than answering: `""` is not a message, and
    /// treating an empty column as text is how a decoder ends up claiming a body it did not
    /// read. A row with an empty `text` and no blob is `.absent`, which is the honest name for
    /// "there is no body here to read".
    static func envelope(for row: MessageRow) -> IMessageEnvelope {
        let body: MessageBody
        let source: MessageBodySource
        if let text = row.text, !text.isEmpty {
            body = .text(text)
            source = .textColumn
        } else if let blob = row.attributedBody {
            body = MessagesDecoder.body(fromAttributedBody: blob)
            source = .attributedBody
        } else if row.payloadData != nil, let bundleID = row.balloonBundleID, !bundleID.isEmpty {
            body = .notText(bundleID: bundleID)
            source = .payloadData
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

    /// One `attributedBody` blob → `.text` or `.unreadable(reason:)`.
    ///
    /// Never `""` and never a throw, on purpose. The failure is a value so the caller can say
    /// something about it, and the reason carries a version byte and an offset — never a byte
    /// of the body — so it can go to the log and to the canary metric without carrying anybody's
    /// message with it.
    static func body(fromAttributedBody blob: Data) -> MessageBody {
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
            guard let text = try reader.firstString() else {
                return .unreadable(reason: .notAString(offset: reader.offset))
            }
            // A stream that parses and holds a zero-length string is a body with no text in it,
            // not a body we could not read. Answering `.text("")` would put the one value this
            // whole task exists to keep out of the pipeline into it, so the invariant below
            // holds instead: **`text` is nil or non-empty, whichever column answered.**
            return text.isEmpty ? .absent : .text(text)
        } catch let failure as MessageDecodeFailure {
            return .unreadable(reason: failure)
        } catch {
            return .unreadable(reason: .structureUnreadable(offset: reader.offset))
        }
    }
}

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
enum MessageBody: Equatable, Sendable {
    /// A body somebody can read. From `text`, or from a decoded stream.
    case text(String)
    /// A body this Mac could not read. **Never the empty string** — there is no way to spell
    /// that here, which is the point.
    case unreadable(reason: MessageDecodeFailure)
    /// Not a text balloon: a tapback, an effect, an app extension's message. The bundle id is
    /// kept so the agent layer can say what arrived.
    case notText(bundleID: String)
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

/// What a caller can say about a body, without being handed the reason's innards.
enum MessageDecodeState: Equatable, Sendable {
    case decoded
    case unreadable(reason: MessageDecodeFailure)
    case notText(bundleID: String)
    /// No body on this row. Not an error, and not an empty message.
    case absent
}

/// Which column produced the body. `.noColumn` is the honest answer for a row that had
/// nothing to read; a source that lied would be worse than no source at all.
enum MessageBodySource: Equatable, Sendable {
    /// `message.text`.
    case textColumn
    /// `message.attributedBody`, decoded.
    case attributedBody
    /// `message.payload_data` + `balloon_bundle_id` — a non-text balloon.
    case payloadData
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
/// string object, and this reader returns as soon as it has it — so every value it has to
/// understand is one of three: an object (`@`, descend), a string (`+` or `*`, take it), or
/// the end of the object. It never has to step over a value whose width it does not know,
/// because it never reaches one. That is the whole of `TYPEDSTREAM-NOTES.md` §5.3's "only the
/// string is wanted, so only the string is modelled" — and it is why a *different* root shape
/// is a refusal rather than a guess.
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

    // MARK: Objects

    /// The first string this reader can justify, or nil when the stream holds none.
    ///
    /// The root of a message body is an object, so the top level is one type-prefixed value
    /// group whose tag is `@`; anything else is refused rather than searched for.
    mutating func firstString() throws -> String? {
        guard let tag = try readSharedString(),
              String(decoding: tag, as: UTF8.self) == "@" else {
            return nil
        }
        return try string(inObjectAt: 0)
    }

    /// Read a literal object and return the first field of it that is a string, descending
    /// into a nested object when the field is one.
    private mutating func string(inObjectAt depth: Int) throws -> String? {
        guard depth <= MessagesDecoder.maxObjectDepth else {
            throw MessageDecodeFailure.structureUnreadable(offset: offset)
        }
        guard try take() == Tag.new_ else {
            // A nil, or a reference to an object written earlier. Neither can be read as a
            // body: there is no first occurrence of a message's own text to point at, so a
            // reference here is a shape this decoder does not know.
            throw MessageDecodeFailure.structureUnreadable(offset: offset)
        }
        let classNames = try readClassChain()
        while true {
            let head = try take()
            if head == Tag.endOfObject { return nil }
            guard let tag = try readSharedString(head: head) else {
                throw MessageDecodeFailure.structureUnreadable(offset: offset)
            }
            switch String(decoding: tag, as: UTF8.self) {
            case "@":
                if let nested = try string(inObjectAt: depth + 1) { return nested }
            case "+", "*":
                // The gate. A character pointer is only the text when the object holding it is
                // a string: `NSNumber`'s first field is the `objCType` `char *` and reading it
                // would answer `q`. Matching on the class *chain* rather than the leaf name
                // means a private concrete subclass (`__NSCFString` and its relations) is
                // recognised through its superclass, which is in the stream, while
                // `NSMutableAttributedString` — which contains the word "String" and holds no
                // text in its first field — is not mistaken for one.
                guard classNames.contains(where: MessagesDecoder.stringClasses.contains) else {
                    throw MessageDecodeFailure.notAString(offset: offset)
                }
                let unshared = tag.count == 1 && tag[0] == UInt8(ascii: "+")
                let raw = unshared ? try readUnsharedString() : try readCString()
                guard let raw else { throw MessageDecodeFailure.notAString(offset: offset) }
                guard let text = String(bytes: raw, encoding: .utf8) else {
                    throw MessageDecodeFailure.notAString(offset: offset)
                }
                return text
            default:
                // A type this reader does not model. Refused, and *not* stepped over: skipping
                // a value means knowing its width, and a reader that guesses widths is a reader
                // that desynchronises and returns a plausible wrong sentence.
                throw MessageDecodeFailure.structureUnreadable(offset: offset)
            }
        }
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
    /// The classes whose first field is the text, matched anywhere in a class chain.
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
}
