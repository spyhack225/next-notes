import CryptoKit
import Foundation

/// IM-08b — the outbound ledger, the match, and the breaker.
///
/// One sentence is what this is for: **it exists so that a row carrying text this app sent is
/// recognised as that row and no other.** Everything else about a message lives somewhere else
/// (`IM-08-DESIGN.md` §3.1).
///
/// ## The failure
///
/// Next Notes is told *"remind me to buy milk"* by voice, sends that to the user's own
/// conversation, and the watcher sees a new row. There are **two** of them, because a
/// self-message lands twice with **opposite `is_from_me`** (IM-01: rows `55189`/`55190`, same
/// 25 characters, same 202-byte body). Without this store the watcher reads its own message back
/// as a fresh command and replies to itself, and an echo answered becomes a loop. The ledger
/// records what was dispatched, matches an incoming row against it, and `IMessageClass`'s
/// `.ownEcho` then says **nothing at all** — no card, no notification, no content in a log. IM-08a
/// enforced that silence four ways at a pure layer; this is what makes the match real.
///
/// ## The allowlist, and why it is one
///
/// `PendingOutboundMessage` below is **nine fields and no free `String`**, for the same reason
/// the decoder's is an allowlist: a denylist of attribute names is a bet on the current macOS
/// release, and the measured graph held eight named attributes plus an unknown nested object.
/// The ledger's version of that argument is sharper, because the design task once said *"do not
/// put contents in a metrics row — `UsageLog.sanitise` exists for that"*, and that was a hole
/// rather than a control:
///
/// > **`UsageLog.sanitise` is blind to prose.** It strips quoted content, addresses, URLs, paths
/// > and long digit runs. **A third party's promotional offer is none of those — it is prose, and
/// > it survives every rule in it.** At sanitisation it is already too late anyway.
///
/// So the constraint is enforced **at construction**: there is no field a caller can put a
/// sentence into, and adding one is a diff somebody has to justify. Three `String` fields exist
/// and all three are **opaque ids** — `chat.guid`, `message.guid`, and IM-11's
/// `conversationID` — each of which is compared against Apple's own value, so a sentence in one
/// matches nothing. `--selftest-imessage-loop` proves what reached the disk with `strings(1)`,
/// because a field-level assertion answers a different question from the one the privacy case
/// asks.
///
/// ## What this file is not, and will not grow into
///
/// - **Not a history of conversations.** A `landed` row is deleted after `retentionDays`; the
///   store is a matching table, and a transcript here would be a second copy of a conversation
///   nobody asked to keep.
/// - **Not a task ledger.** `TaskBridge` (AO P6) owns task state, and this file does not gain a
///   `status` or `task` column.
/// - **Not a count store.** The breaker and the match produce **integers**, and `IMessageUsage`
///   (IM-17d's file, the single writer, not yet in the tree) is where a count becomes a
///   `usage.jsonl` row. Nothing here writes one, and nothing here can carry content into one.
/// - **Not persisted.** The breaker's state is in memory on purpose: a ten-second window does not
///   survive a relaunch, nothing is lost by that, and persisting a rate would be a second store
///   for a number.
enum OutboundLedgerRules {
    /// How far **behind** a row's own date may be and still be our echo: 60 seconds.
    ///
    /// `message.date` is nanoseconds since 2001-01-01 and this Mac's clock is not a guarantee
    /// (§ the one-sided window, below), so the lower bound exists to absorb a row that was
    /// stamped a little before the send we made.
    static let skewNanos: Int64 = 60 * 1_000_000_000

    /// How long after a dispatch a row may still be **identified** as ours: 10 minutes.
    ///
    /// **The number is provisional and the rule is not.** `STATUS.md`'s IM-01 side finding
    /// records `message.date` reading **up to ~6 minutes in the future** on the newest rows. A
    /// *symmetric* window therefore has to be six minutes wide on one side or a real echo is
    /// rejected — and a six-minute window swallows the user's next message, which is a far worse
    /// failure than a rejected echo because a rejected echo is caught by the breaker while a
    /// swallowed command is lost. So the window is one-sided: wide above, one minute below, with
    /// **this** number as the upper bound and no symmetric reading of it below. The design states
    /// the upper bound as the expiry rather than as a second timestamp comparison; this
    /// implementation evaluates it as `withinWindow` does — on the row's own date — which is the
    /// same bound *and* strictly tighter than the wall-clock sweep, so a late sweep cannot widen
    /// the set of rows this app will call its own. **The two numbers here and `skewNanos` are the
    /// two a real capture would move**; the *conjunction* of the conditions is the rule.
    static let pendingExpiryNanos: Int64 = 600 * 1_000_000_000

    /// How long a `landed`, `expired` or `abandoned` row is kept: 7 days.
    ///
    /// Longer than any plausible verification window (IM-10's receipt reads a `landed` row), short
    /// enough that the store does not become an accumulating set of digests of private sentences.
    /// **A `pending` row is never deleted by retention** — it expires on the window above, and a
    /// row that never landed is the crash-recovery case, not garbage to sweep.
    static let retentionDays: Int = 7

    /// Retention in Apple's epoch nanoseconds, for the sweep's one comparison.
    static var retentionNanos: Int64 { Int64(retentionDays) * 86_400 * 1_000_000_000 }

    /// A SHA-256 digest is 32 bytes, always, which is what lets a list of them be stored as one
    /// blob with no framing — and which is why `IMessageOutboundStore.record` refuses a "digest"
    /// of any other length instead of storing a row that could never match.
    static let digestByteCount = 32

    // MARK: - The one-sided window

    /// Whether a row's own date falls inside the identification window of a send.
    ///
    /// **Named, tested, and one-sided on purpose.** `candidateDate >= dispatchedAt - skew` and
    /// `candidateDate <= dispatchedAt + pendingExpiry`, with **no** second reading of the skew in
    /// the other direction. The reason is the measurement above: the spread this has to absorb is
    /// *forward*, so a symmetric bound would have to be as wide as the spread on the side where
    /// the user's own next message lives, and that one costs a real command rather than a count.
    ///
    /// Evaluated on **the row's own date** rather than on the wall clock. That is strictly
    /// tighter than the sweep, which is deliberate: a sweep that ran late, or a crash that
    /// delayed it, must not widen the set of rows this app is willing to call its own.
    static func withinWindow(candidateDate: Int64, dispatchedAt: Int64) -> Bool {
        candidateDate >= dispatchedAt - skewNanos && candidateDate <= dispatchedAt + pendingExpiryNanos
    }
}

// MARK: - The row

/// One message this app sent, and **the only nine facts the store is allowed to keep about it**.
///
/// **An allowlist, not a denylist** (`IM-08-DESIGN.md` §3.2), for the reason the decoder's is
/// one: a list of things not to store is a list of things somebody thought of, and a macOS
/// update adds a ninth. A closed row type is a list of everything there is. Adding a field here
/// is a deliberate act somebody has to justify, and it is visible in the diff.
///
/// **Every field is a number, a digest, an id this app minted, or a closed enum.** The three
/// `String`s are opaque ids — Apple's `chat.guid`, Apple's `message.guid`, and IM-11's
/// `conversationID` — and each is compared against Apple's own value, so there is nothing here a
/// caller can put a sentence into. There is deliberately no `note`, no `text`, no `body`, no
/// `fileName`, no `error` and no `summary`: a failure is an `OutboundState` and a count, and a
/// localised description of a send failure is prose about the user's own machine, which is
/// exactly what survives every sanitiser.
struct PendingOutboundMessage: Equatable, Sendable {
    /// Ours. The correlation id IM-10 and IM-11 carry.
    var id: Int64 = 0
    /// Ours. `chatGUID → conversationID` (IM-11's mapper), so a reply goes back to the
    /// conversation rather than to a string.
    var conversationID: String = ""
    /// Apple's. The join key, and the only reason this store is chat-scoped.
    var chatGUID: String = ""
    /// A digest of the bytes that were sent. **Never the text.** See `OutboundDigest`.
    var textDigest: Data = Data()
    /// A digest per attachment that was sent. **Never a file name** — `report.pdf` is not a path,
    /// so no sanitiser would catch it, and a name carries a person's project, a client and a date.
    var attachmentDigests: [Data] = []
    /// Apple's epoch, nanoseconds.
    var dispatchedAt: Int64 = 0
    /// Set when the row that carries our text is found. `nil` while pending.
    var matchedRowID: Int64?
    /// Apple's. Set at the same moment, for IM-10's receipt.
    var matchedMessageGUID: String?
    /// Not a `String` pair, and not four booleans: a pending row that expires and a pending row
    /// that landed are different facts and the store has to be able to say which.
    var state: OutboundState = .pending
}

/// The four things a send can be. **A closed enum with no payload**, so no diagnosis, no error
/// sentence and no address can ride along with one.
enum OutboundState: String, CaseIterable, Equatable, Sendable {
    /// Persisted, not yet observed.
    case pending
    /// Our row was found and identified.
    case landed
    /// It never landed, and the window closed.
    case expired
    /// A local act gave up on it.
    case abandoned

    /// The two states whose rows are still eligible to be recognised as our echo.
    ///
    /// **`.expired` and `.abandoned` never match, ever** — the design's rule is that "a pending
    /// row that expires goes to `.expired` and can never match a later row", and a row this app
    /// gave up on is not a claim it may make about somebody's conversation afterwards.
    var mayIdentifyAnEcho: Bool { self == .pending || self == .landed }
}

// MARK: - The digest

/// SHA-256 of the bytes that were sent, and of nothing else.
///
/// **Plain SHA-256, and a keyed HMAC was considered and rejected** (`IM-08-DESIGN.md` §3.2): a key
/// beside the digests in the same file does not protect a copy of that file, and a key in the
/// Keychain adds a second store, a second failure and a second thing to migrate for an attacker
/// who would need the file in the first place. The exposure that is real is a *backup* of the
/// app's support directory, and that is Apple's backup of data the app wrote on purpose.
///
/// **No normalisation, and the reason is the safe direction.** The digest is of the exact UTF-8
/// bytes handed to the send, not of a normalised form of them: normalising would paper over a
/// real difference between what this app sent and what Apple stored, and a digest that never
/// matches turns our own echo into a *command* — which is the loop. The digest is the
/// **discriminator**, not the bound: the design is explicit that an assistant repeating the user's
/// exact sentence is the case a time window alone would swallow. Where a digest does fail to
/// match, the failure is counted and the breaker (§ `OutboundLoopBreaker`) is the backstop.
enum OutboundDigest {
    /// The digest of a message body. **The body is the only `String` this file ever digests**, and
    /// it is not stored.
    static func text(_ text: String) -> Data { sha256(Data(text.utf8)) }

    /// The digest of an attachment's bytes. **Never of its name** — see `PendingOutboundMessage`.
    static func attachment(_ bytes: Data) -> Data { sha256(bytes) }

    static func sha256(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }
}

// MARK: - What an incoming row offers the match

/// What the inbound path hands the match: **ids, digests and Apple's epoch — and no text.
///
/// The `textDigest` is computed by the caller from the row's body and is deliberately *not* the
/// body, so this type cannot become a place a sentence is parked either. It is not persisted; the
/// store keeps only the nine fields above.
struct OutboundEchoCandidate: Equatable, Sendable {
    /// Apple's `message.ROWID`. Written to `matchedRowID` when this row is the one that claimed
    /// the send; opaque here.
    var rowID: Int64 = 0
    /// Apple's `message.guid`, for `matchedMessageGUID` — the second half of IM-10's receipt.
    var messageGUID: String = ""
    /// Apple's `chat.guid`, read off the row's `chat_message_join`.
    var chatGUID: String = ""
    var textDigest: Data = Data()
    var attachmentDigests: [Data] = []
    /// Apple's `message.date`, nanoseconds since 2001-01-01. **The row's own clock reading**,
    /// which is the whole reason the window is one-sided.
    var date: Int64 = 0
}

/// What the pure match found. **`EchoVerdict` plus the one fact a caller needs to persist a
/// claim**, and no more: no guid, no digest, no date.
enum OutboundMatch: Equatable, Sendable {
    /// Nothing in the ledger can be this row's send. `EchoVerdict.notOurEcho`.
    case noMatch
    /// Exactly one send in the ledger claims this row. `EchoVerdict.ownEcho`.
    ///
    /// `claimed` is `true` only for the **first** row that names this send — IM-01's two copies
    /// of one self-message both read as ours, and the second one does not re-claim. The design's
    /// `matchedRowID == nil` condition is "one send, one match — a second row cannot claim it",
    /// and that is exactly what `claimed` is: see `OutboundMessageLedger.verdict(for:)` for why
    /// the condition is read as a constraint on the *claim* rather than on the *match*.
    case echo(sendID: Int64, claimed: Bool)
    /// **Two or more sends in the ledger could be this row.** `EchoVerdict.ambiguous`, and the
    /// design's tiebreak applies: treat it as a command, because losing a real request silently
    /// is worse than counting our own echo. Sorted so a report is stable.
    case ambiguous(sendIDs: [Int64])

    /// The classifier's answer, which is the only thing a row's fate is decided by.
    var verdict: EchoVerdict {
        switch self {
        case .noMatch: .notOurEcho
        case .echo: .ownEcho
        case .ambiguous: .ambiguous
        }
    }
}

/// The match, as a pure function of a ledger and a row. **Everything about it is here**, so
/// `--selftest-imessage-loop` can pin the rules without a store, a database or a grant — the same
/// reason `IMessageClass` is pure and every later task is its consumer.
enum OutboundEchoMatch {

    /// Which sends in `ledger` could be this row's send, in the design's order.
    ///
    /// | condition | why |
    /// |---|---|
    /// | the chat matches | a digest is worthless without the conversation |
    /// | the digest matches | the discriminator; an assistant repeating the user's exact sentence is the case a time window alone would swallow |
    /// | the window holds, on the row's own date | absorbs a clock that reads ahead — see `withinWindow` |
    /// | attachment digests match, when any were sent | a photo we sent is recognised as a photo we sent |
    /// | the send may still identify an echo | `.expired` and `.abandoned` never match, ever |
    ///
    /// **The match is on identity, not on text, and the identity is (chat, digest, dispatch
    /// instant).** The two copies of one command share a body because they are one send; a
    /// *different* command with the same words has the same digest and a **different dispatch
    /// instant**, so it is a different send — and when that instant happens to fall inside the
    /// first send's window the two collide, which is the ambiguity below rather than a match.
    static func claims(ledger: [PendingOutboundMessage],
                       candidate: OutboundEchoCandidate) -> [PendingOutboundMessage] {
        ledger.filter { send in
            guard send.state.mayIdentifyAnEcho,
                  send.chatGUID == candidate.chatGUID,
                  send.textDigest == candidate.textDigest,
                  OutboundLedgerRules.withinWindow(candidateDate: candidate.date,
                                                   dispatchedAt: send.dispatchedAt)
            else { return false }
            return attachmentsMatch(sent: send.attachmentDigests, observed: candidate.attachmentDigests)
        }
    }

    /// The verdict, and the ambiguity rule.
    static func verdict(ledger: [PendingOutboundMessage],
                        candidate: OutboundEchoCandidate) -> OutboundMatch {
        let claims = claims(ledger: ledger, candidate: candidate)
        switch claims.count {
        case 0:
            return .noMatch
        case 1:
            let send = claims[0]
            return .echo(sendID: send.id, claimed: send.matchedRowID == nil)
        default:
            return .ambiguous(sendIDs: claims.map(\.id).sorted())
        }
    }

    /// Whether a row carries everything we sent. **Containment, not equality**, and the reason
    /// is the settling race rather than a preference: `message` rows precede their `attachment`
    /// join rows, so a candidate can legitimately carry *more* than the send did, and IM-06's
    /// per-message settle budget is what closes the gap before the match runs.
    ///
    /// **A candidate that carries fewer does not match** — a row read before its attachments
    /// settled is not claimed, which fails toward the user and is counted. The opposite choice
    /// (treating an un-settled row as ours) would let an unmatched photo be swallowed.
    static func attachmentsMatch(sent: [Data], observed: [Data]) -> Bool {
        guard !sent.isEmpty else { return true }
        let seen = Set(observed)
        return sent.allSatisfy(seen.contains)
    }
}

// MARK: - The breaker

/// What one attempted send did. **Three cases, and the middle one is the one that matters**: the
/// flood tripped *on* this message, so it went out and sending is now paused — a refusal after
/// the fact would be indistinguishable from never having tried.
enum OutboundSendDecision: Equatable, Sendable {
    case send
    case sentAndPaused
    case refusedWhilePaused
}

/// The circuit breaker, and the only state in this feature that is **not** persisted.
///
/// > `> 5` agent-authored messages in 10 seconds with no `.userCommand` in the window suspends
/// > sending and raises `pausedReplying` once.
///
/// **In memory, on purpose**: a ten-second window does not survive a relaunch, nothing is lost by
/// that, and persisting it would be a second store for a rate. **A user row resumes it
/// immediately** — the person's own message is the proof the loop is over, and waiting for a
/// timer while they are standing there is exactly the "slow and clumsy" failure `AGENTS.md` rules
/// out.
///
/// This is also the backstop under the digest: a rejected echo is answered as a command, and the
/// design's answer to that is "a rejected echo is answered by the breaker counting it". So the two
/// halves belong in one task — without the ledger there is a flood of messages, and without the
/// breaker a rejected match is a flood too.
struct OutboundLoopBreaker: Equatable, Sendable {
    /// The window, in seconds. Ten seconds is "long enough that a burst of replies is a burst and
    /// not a conversation", and short enough that a person typing six commands in a row is not
    /// paused.
    static let windowSeconds: Double = 10
    /// **More than this many** agent-authored messages inside the window trips it, so the sixth
    /// one is the trip — five in a row is a normal burst of answers to a burst of questions.
    static let threshold: Int = 5

    private(set) var agentSends: [Date] = []
    /// When the user last spoke, if ever. **In the window means not a loop**: the person is here.
    private(set) var lastUserCommand: Date?
    private(set) var isSuspended = false

    /// One attempted send. Decides *and* records in one call, so no caller can decide twice about
    /// one message or record one message twice.
    mutating func noteAgentSend(at now: Date) -> OutboundSendDecision {
        if isSuspended {
            // Nothing was sent, so there is nothing to time and nothing to count as a send. The
            // refusal is not an echo and must not become one: a reply that was never sent cannot
            // come back and match.
            return .refusedWhilePaused
        }
        agentSends.append(now)
        prune(at: now)
        guard agentSends.count > Self.threshold, !userSpokeInsideWindow(at: now) else { return .send }
        isSuspended = true
        return .sentAndPaused
    }

    /// One `.userCommand` row. Resumes immediately, and says so, so the bridge can drop the
    /// island card on the turn that ends the pause rather than on a timer.
    mutating func noteUserCommand(at now: Date) -> OutboundLoopEvent {
        lastUserCommand = now
        agentSends.removeAll()
        guard isSuspended else { return .none }
        isSuspended = false
        return .resumed
    }

    /// Forgets the window without resuming — a local act giving up (`OutboundState.abandoned`).
    mutating func reset() {
        agentSends.removeAll()
        lastUserCommand = nil
        isSuspended = false
    }

    /// The user has spoken inside the window, so however many messages went out they were answers
    /// to a person and not a loop.
    private func userSpokeInsideWindow(at now: Date) -> Bool {
        guard let lastUserCommand else { return false }
        return now.timeIntervalSince(lastUserCommand) < Self.windowSeconds
    }

    /// Pruning on every send bounds the array without a second structure, and the bound is the
    /// threshold: a stamp older than the window cannot contribute to the count, so nothing older
    /// than the newest `threshold + 1` stamps can ever make the next send trip.
    private mutating func prune(at now: Date) {
        agentSends.removeAll { now.timeIntervalSince($0) > Self.windowSeconds }
    }
}

/// The one thing the breaker did that a person can see. `IMessageClassifierCopy.pausedReplying` is
/// the sentence, and it is raised **once** per pause and never per row.
enum OutboundLoopEvent: Equatable, Sendable {
    case none
    case suspended
    case resumed
}

// MARK: - The counts

/// Everything this feature made observable, as **integers**.
///
/// **A count only — never a text, an address, a guid, a row id or a hash of content.** A hash of
/// somebody's message is still a fingerprint of it, and so is a row id that a report could join
/// back to a transcript. `IMessageUsage` (IM-17d) is the single writer that turns these into
/// `usage.jsonl` rows under §2.4's own vocabulary — `echoMatched`, `accepted`, `refused`,
/// `unreadable`, `notText`, `noBody`, `notPaired`, `loopSuppressed` — and it does not exist yet, so
/// this file records them in memory, logs them as numbers, and grows no second store. **Nothing
/// here is a row about a person**: `.echoesBroken` says a message this app sent came back and was
/// recognised, which is a fact about this app's own behaviour.
struct OutboundLedgerCounts: Equatable, Sendable {
    /// Sends recorded before dispatch.
    var dispatches: Int = 0
    /// Rows recognised as this app's own message and broken out of the inbound path. **One per
    /// send, not per row** — IM-01's two copies are one echo.
    var echoesBroken: Int = 0
    /// Rows that two sends could both have been. The design's ambiguity, and each one is a real
    /// echo that was **not** claimed.
    var ambiguities: Int = 0
    /// Pending rows that reached `pendingExpiry` without being claimed.
    var expirations: Int = 0
    /// Sends the breaker refused while paused.
    var refusalsWhilePaused: Int = 0
    /// Times the breaker suspended.
    var suspensions: Int = 0

    /// One line, numbers only. The `usage.jsonl` row is IM-17d's; this is what a person reading
    /// the log sees, and it cannot carry content because every field is an `Int`.
    var summary: String {
        "imessage loop · dispatches \(dispatches) · echoes broken \(echoesBroken) · "
            + "ambiguous \(ambiguities) · expired \(expirations) · paused \(suspensions) · "
            + "refused while paused \(refusalsWhilePaused)"
    }
}

// MARK: - The ledger

/// The ledger: a store, a breaker, and the counts. **An actor**, because the store is behind a
/// SQLite connection and the breaker is mutable state, and the inbound path reads it from wherever
/// the watcher is running.
///
/// **The pending row is written before the Apple Event is dispatched** — the design's rule,
/// unchanged — so a crash in the gap is a pending row that expires rather than an echo with
/// nothing to match it. That ordering is the whole reason this is a store and not a dictionary:
/// the row has to survive the process.
actor OutboundMessageLedger {
    private let store: IMessageOutboundStore
    /// Injected so `--selftest-imessage-loop` can drive a ten-minute window instantly. The
    /// production value is Apple's epoch in nanoseconds, which is the clock both the store and the
    /// row's own `date` are in.
    private let nowNanos: @Sendable () -> Int64
    /// The breaker reads wall-clock `Date`s and the window is ten seconds, so the production
    /// value is `Date.init`. Injected for the same reason.
    private let nowWallClock: @Sendable () -> Date
    private var breaker = OutboundLoopBreaker()
    private(set) var counts = OutboundLedgerCounts()

    init(store: IMessageOutboundStore,
         nowNanos: @escaping @Sendable () -> Int64 = { OutboundMessageLedger.appleEpochNow },
         nowWallClock: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.nowNanos = nowNanos
        self.nowWallClock = nowWallClock
    }

    /// The production ledger. Under the self-test harness its root is a per-process temporary
    /// directory, exactly like `UsageLog.shared`, so **no run can append to the owner's file** —
    /// and `--selftest-store-isolation` watches the owner's three files to prove it.
    static let shared = OutboundMessageLedger(store: IMessageOutboundStore())

    /// `message.date` is nanoseconds since 2001-01-01, which is 978307200 seconds after the Unix
    /// epoch. Every number this feature compares is in **that** clock, including the store's
    /// retention sweep, so nothing here mixes the two epochs.
    static let appleEpochOffsetSeconds: Double = 978_307_200
    static var appleEpochNow: Int64 {
        Int64((Date().timeIntervalSince1970 - appleEpochOffsetSeconds) * 1_000_000_000)
    }

    // MARK: Sending

    /// Records a send **before** it is dispatched, and asks the breaker whether it may go.
    ///
    /// - Returns: the decision, so the caller dispatches on `.send` and `.sentAndPaused` and
    ///   **does not dispatch at all** on `.refusedWhilePaused` — and raises
    ///   `IMessageClassifierCopy.pausedReplying` on `.sentAndPaused` only.
    /// - Throws: `IMessageOutboundStoreError`, and the caller must not dispatch when it does. A
    ///   send this app cannot record is a send it will not recognise coming back, so refusing it
    ///   is the only safe answer.
    @discardableResult
    func recordDispatch(chatGUID: String,
                        conversationID: String,
                        textDigest: Data,
                        attachmentDigests: [Data] = [],
                        dispatchedAt: Int64? = nil) throws -> OutboundSendDecision {
        let decision = breaker.noteAgentSend(at: nowWallClock())
        switch decision {
        case .refusedWhilePaused: counts.refusalsWhilePaused += 1
        case .sentAndPaused: counts.suspensions += 1
        case .send: break
        }
        guard decision != .refusedWhilePaused else { return decision }
        try store.record(PendingOutboundMessage(
            id: 0,
            conversationID: conversationID,
            chatGUID: chatGUID,
            textDigest: textDigest,
            attachmentDigests: attachmentDigests,
            dispatchedAt: dispatchedAt ?? nowNanos(),
            matchedRowID: nil,
            matchedMessageGUID: nil,
            state: .pending))
        counts.dispatches += 1
        return decision
    }

    /// A local act gave up on a send before it was dispatched, so no row can arrive for it.
    @discardableResult
    func abandon(chatGUID: String, textDigest: Data) throws -> Int {
        let changed = try store.markAbandoned(chatGUID: chatGUID, textDigest: textDigest)
        if changed > 0 { breaker.reset() }
        return changed
    }

    // MARK: The inbound path

    /// The match. **The trust decision is this function's answer**, and the one thing that can
    /// make a row ours.
    ///
    /// - `matchedRowID == nil` is read as a constraint on the **claim**, not on the match, and
    ///   that is the one place this file interprets the design's table. The design states the
    ///   condition's purpose — *"one send, one match — a second row cannot claim it"* — and the
    ///   purpose is preserved exactly: the first row that names a send writes `matchedRowID` and
    ///   moves it to `.landed`, and every later row naming the same send reads `.ownEcho`
    ///   **without** re-claiming. Reading the condition as a constraint on the *match* as well
    ///   would be a loop: IM-01's second copy arrives after the first copy claimed the send, finds
    ///   nothing, and is classified a **command** — which is the failure the whole ledger exists to
    ///   prevent. The two copies are also collapsed upstream, by the watcher's guid cache or
    ///   IM-08d's command fingerprint, and this is not a second mechanism for that; it is the one
    ///   place where the collapse is not allowed to be the only defence.
    /// - The match is `await`ed from the bridge rather than done inline, and the inbound path is
    ///   already reading a database and a WAL, so this is one hop on a path that is not a person's
    ///   dictation turn.
    func verdict(for candidate: OutboundEchoCandidate) async throws -> EchoVerdict {
        try sweep()
        let match = OutboundEchoMatch.verdict(ledger: try store.claimableRows(), candidate: candidate)
        switch match {
        case .noMatch:
            return .notOurEcho
        case .ambiguous(let sendIDs):
            counts.ambiguities += 1
            // The number of candidate sends and nothing else. Which sends could have claimed
            // this row is a list of ids, and a row id is as much a fingerprint of somebody's
            // message as a digest of it, so only the count reaches the log.
            Log.app.info("imessage loop · a row could be any of \(sendIDs.count) sends; treated as a command")
            return .ambiguous
        case .echo(let sendID, let claimed):
            if claimed {
                try store.markLanded(sendID: sendID, rowID: candidate.rowID,
                                     messageGUID: candidate.messageGUID)
                counts.echoesBroken += 1
            }
            return .ownEcho
        }
    }

    /// One `.userCommand` row. Resumes the breaker immediately and is the only thing that does.
    @discardableResult
    func noteUserCommand(at wallClock: Date? = nil) -> OutboundLoopEvent {
        let event = breaker.noteUserCommand(at: wallClock ?? nowWallClock())
        if event == .resumed { Log.app.info("imessage loop · a message from the user resumed replying") }
        return event
    }

    // MARK: Retention

    /// Two statements, no timer, and no new scheduler: expire what cannot be identified any more,
    /// then delete what has been decided for longer than the retention window. Called from the
    /// write paths and available for a launch-time call.
    @discardableResult
    func sweep(now: Int64? = nil) throws -> Int {
        let clock = now ?? nowNanos()
        let expired = try store.expirePending(olderThan: clock - OutboundLedgerRules.pendingExpiryNanos)
        if expired > 0 {
            counts.expirations += expired
            Log.app.info("imessage loop · \(expired) send(s) never landed and the window closed")
        }
        let deleted = try store.deleteSettled(olderThan: clock - OutboundLedgerRules.retentionNanos)
        return deleted
    }

    // MARK: Reading, for tests and for `--imessage-report`

    func rows() throws -> [PendingOutboundMessage] { try store.allRows() }
}
