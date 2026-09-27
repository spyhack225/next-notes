import Foundation

/// IM-08a — what a remote message **is**, as a pure function.
///
/// One function, four inputs, and the parameter list is the design:
///
/// ```swift
/// IMessageClassifier.classify(body: MessageBody, isFromMe: Bool,
///                              sender: ResolvedSender, echo: EchoVerdict)
/// ```
///
/// **Why `IMessageEnvelope` is deliberately not among them, and why that is the load-bearing
/// decision of this task.** Everything a class needs is the body, the column, the row's
/// resolved sender and the ledger's answer. So `rowID`, `guid`, `date`, `service`, `source`,
/// a future `attachments`, and every field a later task adds to the envelope **cannot change a
/// class**, because there is nowhere to pass them. The output has no slot for them either:
/// `IMessageClassification` is a class, a `Bool` and a closed enum, so a field added to the
/// envelope has nothing to land in. That is the same enforcement as `MessageBody` having no
/// empty-string case and as `OutputToken`'s initializer being `fileprivate` to its file — a
/// rule that is only true if you try to break it. `IM-08a-red.txt` records the compiler
/// refusing the call, because a claim about a signature is worth less than the refusal.
///
/// **It is also what settles the voice note structurally.** `MessageBodySource` —
/// `.textColumn`, `.attributedBody`, `.payloadData`, `.isAudioMessage`, `.noColumn` — **never
/// reaches this file**. Whether a voice note is recognised by the walk's `U+FFFC` rule or by
/// `is_audio_message`, and whether the real row shape is ever captured
/// (`voice-note-row-shape-from-a-real-message` is still blocked), the class is the same on both
/// and the measurement can no longer change IM-08a. It changes IM-15's *handling*, which reads
/// the source and the attachment.
///
/// ## The four measurements this table is built on
///
/// 1. **A self-message is TWO rows** — `55189` `is_from_me = 1` and `55190`
///    `is_from_me = 0`, same 25 characters, same 202-byte body, **opposite column**
///    (`TYPEDSTREAM-NOTES.md`, *A self-message is TWO rows*). So `is_from_me` **cannot
///    identify a self-message**: it cannot tell the two copies apart, and which copy a filter
///    gets is not something the row decides. That is why the ledger answers that question
///    alone and the column only ever contributes *"this Mac sent it"*. A classifier written
///    with a row-level `is_from_me` test is the error this roadmap is most likely to make
///    twice, and `the_two_copies_of_one_command_classify_identically` is the assertion.
/// 2. **A self-chat is a thread on your own number, so a row in it can be from somebody
///    else.** That is the whole reason `.fromSomebodyElse` exists, and the reason "in the
///    paired chat" is not `.userCommand`. `00-README` §11 says *"A `from-me` row that matches a
///    pending outbound is ours; everything else is a user command"*, and the second clause is
///    wrong for this chat: a conversation with yourself is addressed to your own number, and
///    anybody with it can text it.
/// 3. **Refusals are direction-free.** An effect (a text balloon whose whole string is `U+FFFC`)
///    and a voice note are `.userSentSomethingElse` when the sender is the user and
///    `.fromSomebodyElse` when it is not — *the refusal is the same, only the direction
///    differs*. `.couldNotRead` and `.nothingToRead` do not consult the direction at all,
///    because nothing is done about them either way.
/// 4. **`.notText` carries `bundleID: String?` and it is `nil` on every real effect and voice
///    note measured** — `balloon_bundle_id` is NULL on all four of the 2026-09-26 rows. So a
///    class may not require one, and a caller cannot be written to print an identity the
///    database does not have. Every type here is a closed enum with **no payload**, so there
///    is no `String` anywhere a caller could put a sentence, an address or a bundle id.
///
/// ## The order, and the four disagreements
///
/// Ledger → refusals → direction, because the ledger is the only signal about **this app's own
/// behaviour** rather than about a row this process did not write, and the only failure that is
/// both silent and self-amplifying: an echo answered becomes a loop, and the loop is what ends
/// the feature. The refusals come before the direction because `.unreadable` and `.absent`
/// cannot tell us who sent the row, so asking would be asking a question the inputs cannot
/// answer. Each disagreement is resolved in `classify` with the reason on it, and each has a
/// case that reddens if it is resolved the other way.
///
/// | disagreement | winner | why |
/// |---|---|---|
/// | the ledger says echo, the column says `false` | **the ledger** | the two copies of one self-message carry opposite values, so the column cannot veto anything |
/// | two pending rows match one row | **it is a command** | losing a real request silently is worse than counting our own echo, and this default only ever moves a row *toward* the user |
/// | `MessageBodySource` vs `MessageBody` | **the body** | the source is not a parameter — the voice note's whole answer |
/// | the column says `true`, the resolved handle says somebody else | **the column** | a row this Mac dates from this Mac came from this Mac, and the handle on an outgoing row is a *recipient* |
///
/// ## What this file is not, and will not grow into
///
/// - **No store, no ledger, no clock, no task, no model, no grant, no pairing.** Four values in,
///   one value out. A need for anything else is a finding about the seam, not a parameter to
///   add here.
/// - **No authority.** A class is not an authority: `AgentRisk` grades a *tool*, and the class
///   decides whether there is a turn for a tool to run inside. What a turn may do is
///   `AgentCapabilityManifest`'s answer and nobody else's — a second tool list inside this
///   feature is the exact thing that rule exists to prevent.
/// - **No count vocabulary.** §2.4 of the design maps each class onto `IMessageCount`
///   (`echoMatched`, `accepted`, `refused`, `unreadable`, `notText`, `noBody`) and those cases
///   are IM-17d's file, written once, with `IMessageUsage` as the only writer. `echoMatched` is
///   a number and **not** a row about a person: a store or a log that recorded *"somebody else
///   wrote to you"* would be a record of somebody else's words by adjacency, even with no words
///   in it.
/// - **No pairing question.** Whether a chat is the self channel is a *chat* question, answered
///   once at the pairing act and frozen (IM-07), and the bridge reads only the paired chat
///   before it gets here. Putting it in this signature would make a per-row function answer a
///   per-chat one.
enum IMessageClassifier {

    // MARK: - The one function

    /// What a remote row is. Four values in, one value out, and the order below is the design.
    ///
    /// - Parameters:
    ///   - body: the one stored fact about the message, from `MessagesDecoder`. Never the
    ///     envelope: there is nowhere to pass a row id, a guid, a date or a source.
    ///   - isFromMe: `message.is_from_me` — **a column, not a direction.** It contributes
    ///     "this Mac sent it" and nothing else. On its own it cannot identify a self-message
    ///     (§ the four measurements, 1).
    ///   - sender: the row's own handle, resolved against the paired number by IM-08c. Its
    ///     `.thisMac` case is the column's contribution in the sender's own vocabulary, so a
    ///     `.thisMac` **with** `isFromMe == false` is a disagreement rather than a fact, and it
    ///     fails closed below.
    ///   - echo: the ledger's answer, and the only thing that can make a row ours.
    static func classify(body: MessageBody,
                         isFromMe: Bool,
                         sender: ResolvedSender,
                         echo: EchoVerdict) -> IMessageClassification {
        // 1. **The ledger, first and alone.** A matched, unambiguous echo is `.ownEcho`
        //    whatever the body is and whatever the column says: our own photo coming back is
        //    not text, and our own text landing with `is_from_me = 0` is a fact the two-row
        //    measurement makes routine. The column is **not** a veto here, and neither is the
        //    body. Nothing about this row is consulted, so there is no direction to report.
        if echo == .ownEcho {
            return IMessageClassification(messageClass: .ownEcho,
                                          carriesLink: carriesLink(body),
                                          directionEvidence: .notConsulted)
        }

        // 2. **The refusals, before the direction.** `.unreadable` and `.absent` cannot say who
        //    sent the row, so the direction is not asked for; the answer is the same whoever
        //    sent it, and a cell per refusal would be six cases to keep in agreement with no
        //    behaviour to show for it. The `MessageDecodeFailure` stays on the envelope for
        //    the canary and the report — folding it into the class is what keeps one
        //    vocabulary, and it costs the report nothing because the report reads the
        //    envelope.
        switch body {
        case .unreadable:
            return IMessageClassification(messageClass: .couldNotRead,
                                          carriesLink: false,
                                          directionEvidence: .notConsulted)
        case .absent:
            return IMessageClassification(messageClass: .nothingToRead,
                                          carriesLink: false,
                                          directionEvidence: .notConsulted)
        case .text(let text, _):
            // 3. **The direction, for a row that has words in it** — and `.text` whose string
            //    is empty is a row with no words, not a command. Unreachable from
            //    `MessagesDecoder` (`:371` maps a decoded zero-length stream to `.absent` and
            //    `:278` refuses an empty column), and the branch is here anyway: the decoder
            //    should not have to be re-proved by every caller, and "there is a sentence"
            //    is the question, not "the body case is `.text`".
            let evidence = direction(isFromMe: isFromMe, sender: sender)
            let messageClass: IMessageClass
            if !evidence.isTheUser {
                messageClass = .fromSomebodyElse
            } else {
                messageClass = text.isEmpty ? .userSentSomethingElse : .userCommand
            }
            return IMessageClassification(messageClass: messageClass,
                                          carriesLink: carriesLink(body),
                                          directionEvidence: evidence)
        case .notText:
            // 4. **A balloon with no sentence in it, in whichever direction it came.** The
            //    refusal is the same either way; only the direction differs, and the direction
            //    is the only thing that changes what happens. `bundleID` is deliberately not
            //    read: it is a `com.apple.*` identifier that is `nil` on every measured row,
            //    and a person shown one learns nothing they can act on.
            let evidence = direction(isFromMe: isFromMe, sender: sender)
            return IMessageClassification(
                messageClass: evidence.isTheUser ? .userSentSomethingElse : .fromSomebodyElse,
                carriesLink: false,
                directionEvidence: evidence)
        }
    }

    /// The direction, in one place, and the two disagreements it settles.
    ///
    /// **The column first.** A row this Mac dates from this Mac came from this Mac, and the
    /// handle on an outgoing row is a *recipient* — so a future release that made the two
    /// disagree would be a bug in the reader, not a reason to prefer the weaker signal.
    ///
    /// **`.thisMac` with `is_from_me = 0` fails closed.** That combination is a resolver that
    /// has not been given the column, and a resolver that guesses "this Mac" on an incoming row
    /// would turn a stranger's message into a command. §2.2's rule is the one that applies: a
    /// *sender* ambiguity fails closed, while a *ledger* ambiguity fails open, because they
    /// answer different questions and the recoverable error is different in each.
    static func direction(isFromMe: Bool, sender: ResolvedSender) -> DirectionEvidence {
        if isFromMe { return .thisMac }
        switch sender {
        case .thisMac: return .unresolved
        case .localNumber: return .localNumber
        case .foreignNumber: return .foreignNumber
        case .unresolved: return .unresolved
        }
    }

    // MARK: - The link

    /// Whether **the sender's own typed words** carry a link. A fact about the text, and the
    /// only thing in a remote turn that is an action waiting to happen.
    ///
    /// **A link does not change the class.** A sentence with a URL in it is a
    /// `.userCommand`; `carriesLink` is the only thing that differs. Classification is about
    /// who wrote it.
    ///
    /// > ### A link is content, not an instruction.
    /// >
    /// > A remote turn whose words carry a link may be **answered from words**. It may not, on
    /// > the strength of the link alone, cause a fetch, a sign-in, a download, a page to be
    /// > opened, or anything else that leaves this Mac. Following a link is at least
    /// > `AgentRisk.read` on somebody else's server, and a remote origin may only **lower**
    /// > what policy permits — so a phone can never raise it.
    /// >
    /// > This is the place to read that before adding a "follow that link" feature. The flag
    /// > below is a **description of text**, and there is no code path from it to a network
    /// > request in this file or in any other. Whether `browser`/`fetch` is reachable on a
    /// > `.iMessage` turn is `AgentCapabilityManifest`'s decision, made there and nowhere else
    /// > (`AGENTS.md`: one source of truth for what a turn may do, and a second tool list
    /// > inside this feature is the exact thing that rule exists to prevent).
    ///
    /// **This is the sender's own typing, not Apple's detection.** A real body on this Mac
    /// carried a `__kIMDataDetectedLinkAttributeName` URL and a link preview, and neither
    /// reaches this layer: the decoder's return type means the only string in a body is the one
    /// the sender typed. So the question is not about Apple's detected link, it is about a
    /// word the person wrote — which is the difference between a link they sent and a link
    /// somebody's marketing put in their message.
    static func carriesLink(_ body: MessageBody) -> Bool {
        guard case .text(let text, _) = body else { return false }
        return containsALink(text)
    }

    /// Whether the sender's whole sentence is one link and nothing else — the shape §4.2 rule 3
    /// gives `IMessageClassifierCopy.linkNotFollowed`.
    ///
    /// **A heuristic, and deliberately the blunt one.** A token is a link when it carries a
    /// scheme or a `www.` host, and a turn is link-only when every whitespace-separated token in
    /// it does. So `https://example.com/a` on its own is a link-only turn, and
    /// `https://example.com/a what do you think` is not — it deserves an answer from its words.
    /// A bare hostname is not a link here at all, so `read example.com` is never link-only.
    ///
    /// The consequence of being wrong is which of two sentences is chosen — never whether
    /// anything is fetched — so the blunt reading is the safe one, and the narrow one belongs to
    /// whoever knows whether the words were enough (IM-13).
    static func isOnlyALink(_ body: MessageBody) -> Bool {
        guard case .text(let text, _) = body else { return false }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, words.contains(where: isLinkToken) else { return false }
        return words.allSatisfy(isLinkToken)
    }

    /// Any `scheme://` with a real scheme, or a `www.`-prefixed host, anywhere in the text.
    ///
    /// **No scheme list, on purpose.** A list of the schemes to recognise is a bet on this
    /// release, and the only thing this predicate is asked is "is there a link in these words".
    /// Nothing is ever fetched from the answer, so a scheme nobody listed costs one sentence
    /// that could have been different and no capability at all. A bare hostname with no scheme
    /// is deliberately **not** a link: under-reporting is the safe direction for the same
    /// reason, and a turn saying "read example.com" deserves an answer from its words.
    private static func containsALink(_ text: String) -> Bool {
        guard let separator = text.range(of: "://") else { return startsWithWWW(text) }
        // Walk back over the scheme: letters, digits, `+`, `-` and `.`.
        var start = separator.lowerBound
        while start > text.startIndex {
            let previous = text.index(before: start)
            let character = text[previous]
            guard character.isASCII,
                  character.isLetter || character.isNumber || character == "+"
                    || character == "-" || character == "."
            else { break }
            start = previous
        }
        let scheme = text[start..<separator.lowerBound]
        // A scheme has to be at least two characters and start with a letter, so `://` inside
        // ordinary prose is not a link and a sentence is not turned into one by a colon.
        guard scheme.count >= 2, let first = scheme.first, first.isLetter else {
            return startsWithWWW(text)
        }
        return true
    }

    private static func startsWithWWW(_ text: String) -> Bool {
        var search = text.startIndex
        while search < text.endIndex,
              let found = text.range(of: "www.", options: .caseInsensitive,
                                     range: search..<text.endIndex) {
            if found.lowerBound == text.startIndex { return true }
            let previous = text[text.index(before: found.lowerBound)]
            if !previous.isLetter && !previous.isNumber { return true }
            search = found.upperBound
        }
        return false
    }

    /// One whitespace-separated token that is a link, ignoring the sentence punctuation a person
    /// types around it. `www.` counts here too, so "www.example.com." is a link-only turn.
    private static func isLinkToken(_ token: String) -> Bool {
        var candidate = token
        while let last = candidate.last, ".,;:!?)]'\"".contains(last) {
            candidate.removeLast()
        }
        return !candidate.isEmpty && containsALink(candidate)
    }
}

// MARK: - The class

/// What a remote message is. Six cases, and the collapse from the design's 3 × 4 is one
/// sentence: **the only two things that change what the app does are whether this row is the
/// user's and whether there is a sentence in it; every other cell is a refusal, and a refusal
/// behaves the same whoever sent it.**
///
/// The `String` raw values are for a report and a test to name a class by. **A metrics row must
/// not carry one** — §2.4's vocabulary is `IMessageCount`'s, and it is IM-17d's file.
enum IMessageClass: String, CaseIterable, Equatable, Sendable {
    /// The user's own words, in the paired conversation. **The only class in which a tool can
    /// run at all**, and the only one `AgentSession.recordUser` is called for.
    case userCommand
    /// From the user, and the body carried no words: an effect, a voice note, a tapback, a
    /// balloon this Mac read and found empty of a sentence. One sentence back, and nothing
    /// else — no turn, no memory, no tool.
    case userSentSomethingElse
    /// In the paired conversation, not from the user, and not from us. **Silence on the phone**
    /// and one card on the Mac: a reply to a row we could not identify who wrote is a message
    /// to a stranger that reveals there is an assistant on this number, and "I couldn't read
    /// your message" is worse still, because it tells them to try again.
    case fromSomebodyElse
    /// This Mac could not read the body. **No new sentence**: IM-17's canary owns the one
    /// sentence that exists for it, and a second one saying the same thing in different words is
    /// the drift `IMessageConsentCopy` exists to prevent.
    case couldNotRead
    /// The row carries no body at all — an SMS, or a row older than iMessage. Nothing, ever.
    case nothingToRead
    /// Next Notes' own message, recognised by the ledger. **Says nothing, ever**, and that
    /// silence is the feature: if Next Notes sends "remind me to buy milk" and then reads its
    /// own message back, replying to itself is the failure the whole ledger exists to prevent.
    case ownEcho
}

// MARK: - The value

/// What one row turned out to be. **Three fields, and none of them is a `String`.**
///
/// That is not tidiness, it is the second half of the load-bearing decision: with no string
/// field there is nowhere for a row id, a guid, a date, a service, an attachment, a detected
/// entity, a link, a bundle id or a sentence about somebody's message to land, so a field added
/// to `IMessageEnvelope` later cannot change a class *or* travel with one.
struct IMessageClassification: Equatable, Sendable {
    var messageClass: IMessageClass
    /// Whether the sender's own words carry a link. See `IMessageClassifier.carriesLink` — and
    /// read the note there before adding anything that acts on it.
    var carriesLink: Bool
    /// Which of the four answers produced the direction, as a closed vocabulary. **Never an
    /// address**, so `--imessage-report` can say *"3 messages were from a number Next Notes
    /// couldn't check against yours"* without holding one.
    var directionEvidence: DirectionEvidence
}

// MARK: - The four inputs

/// Which of the four produced the direction. A closed vocabulary on purpose: this is the field
/// a report counts over, and a free string here would be a sentence somebody could write a
/// third party's words into.
enum DirectionEvidence: String, CaseIterable, Equatable, Sendable {
    /// The column says this Mac sent it.
    case thisMac
    /// The row's sender resolved to the paired number — the user, from their phone or another
    /// Mac. **A feature, not an edge case.**
    case localNumber
    /// It resolved, and it is somebody else's.
    case foreignNumber
    /// It could not be resolved at all, or the column and the resolver disagreed. **Fails
    /// closed** — see `IMessageClassifier.direction`.
    case unresolved
    /// **The direction was not consulted, and so there is none to report.** The three classes
    /// that reach this: an echo (the ledger decided before direction existed), a body this Mac
    /// could not read, and a row with no body at all. Without it, one of those rows would have
    /// to carry a direction nobody looked up, and a report would print a claim about a sender
    /// that was never resolved — or, worse, about a sender that *was* resolved, for a row whose
    /// whole answer was that nothing was done with it.
    case notConsulted

    /// Whether this direction means the user. **One** definition of it in the file, so the
    /// classifier and the tests cannot answer it two ways.
    var isTheUser: Bool { self == .thisMac || self == .localNumber }
}

/// The row's own handle, resolved against the paired number. An input, never an output: what
/// came back is a `DirectionEvidence`.
///
/// The `.thisMac` case exists in this vocabulary because the column's contribution is a
/// direction too — but the **resolver cannot produce it from a handle**, which is why
/// `.thisMac` together with `is_from_me = 0` is treated as a disagreement and fails closed.
enum ResolvedSender: CaseIterable, Equatable, Sendable {
    /// The column says this Mac sent it. Only reachable with `is_from_me = 1`.
    case thisMac
    /// The handle resolved to the paired number.
    case localNumber
    /// It resolved, and it is somebody else's.
    case foreignNumber
    /// Nothing resolved — no local identity, no pairing, or no participants join.
    case unresolved
}

/// The ledger's answer about **this app's own behaviour**, and the only input that can make a
/// row ours.
enum EchoVerdict: Equatable, Sendable {
    /// One pending row matched, unambiguously. Ours.
    case ownEcho
    /// Nothing matched. The ordinary case, and everything that is not an echo is decided without
    /// the ledger being consulted again.
    case notOurEcho
    /// **Two pending rows matched one row** — the phase file's ambiguity. It is resolved as
    /// *not our echo*, and the reason is the task's own: treating a real request as our own
    /// message loses it silently, while treating our own echo as a command is a no-op the
    /// breaker counts. This default only ever moves a row **toward** the user, never away.
    case ambiguous
}

// MARK: - What a class is allowed to do

/// The classes that may put anything at all in front of the sender, as **their own enum**.
///
/// **This is the type-level half of `.ownEcho`'s silence.** `.ownEcho` has no case here, and
/// because `IMessageClassification.messageClass` is a *different* enum, the only way to reach a
/// sentence with an echo in your hand is a conversion somebody has to write — and that
/// conversion is one `switch`, which Swift will not let go stale: a seventh `IMessageClass` is
/// a compile error until somebody decides whether it speaks.
enum IMessageRemoteSpeaker: String, CaseIterable, Equatable, Sendable {
    case userCommand
    case userSentSomethingElse
}

extension IMessageClass {
    /// Whether a turn may exist for this class at all. **`nil` for four of the six**, and
    /// `.ownEcho` first among them.
    ///
    /// This is the gate in front of `AgentSession.recordUser` — the single path into memory
    /// (`RealtimeAgent.recordUser(_:source:)`). An echo never reaches it — the roadmap's older
    /// spelling of that class is `.nextNotes`, and §1.2 gives it its one home here — and neither
    /// does a stranger's: there is no turn, so there is nothing for a tool to run inside and
    /// nothing to remember.
    var remoteSpeaker: IMessageRemoteSpeaker? {
        switch self {
        case .userCommand: .userCommand
        case .userSentSomethingElse: .userSentSomethingElse
        case .ownEcho, .fromSomebodyElse, .couldNotRead, .nothingToRead: nil
        }
    }
}

/// Everything that can be said back to a phone, as a closed value with no payload.
///
/// **The remote side says almost nothing, and that is the design.** A refusal says nothing at
/// all on the remote side and everything on the local side; the person who can act on it is the
/// one sitting at the Mac.
enum IMessageRemoteAnswer: Equatable, Sendable {
    /// Nothing goes back to the phone: a stranger's row, a body this Mac could not read, a row
    /// with no body, and — above all of them — an echo. Four of the six classes.
    case nothing
    /// The agent's own answer, formatted by IM-13 with the name the person chose. Nothing in
    /// this file writes it — the same agent answers voice and text, and a second format for one
    /// answer is the drift this feature must not add.
    case theAgentsReply
    /// Something arrived and there are no words in it: `IMessageClassifierCopy.sentSomethingElse`.
    /// One sentence, and it names no kind of thing, because the class cannot know which arrived.
    case noWordsToRead
    /// The turn carried a link and the words were not enough: `IMessageClassifierCopy.linkNotFollowed`.
    ///
    /// **This is the ceiling, not the rule.** IM-08 can see that a link was in the turn; it
    /// cannot see whether the agent answered it from the words, and only IM-13 knows that. So
    /// this case says the safe thing — a link was here and nothing may follow it — and IM-13
    /// narrows it with `isOnlyALink`, a narrowing that can only ever refuse more.
    case theLinkWasNotFollowed
}

/// What the person at the Mac is told about one row, as a closed value with no payload.
enum IMessageLocalNotice: Equatable, Sendable {
    /// Nothing. Five of the six classes: both command classes, a body this Mac could not read, a
    /// row with no body, and the echo. **Only a stranger's row draws a card.**
    case nothing
    /// A stranger's row: `notFromYou` over `notFromYouDetail`. **Deduplicated upstream** so
    /// forty rows in a row are one card and a count of forty — a card per row is noise, and
    /// this layer is not where that is decided.
    case notFromYou
    /// A row from a number that would not resolve, or a column and a resolver that disagreed.
    /// **A different sentence because the cause is different**, and this one is a defect to fix
    /// rather than a stranger.
    case senderUnresolved
}

extension IMessageClassifier {
    /// The one place a class turns into something that goes **to the phone**. `.nothing` for
    /// four of the six, and an echo is a refusal here in the strongest sense: it is our own text
    /// coming back, and the loop-breaker case is the one failure that is silent *and*
    /// self-amplifying.
    static func remoteAnswer(for classification: IMessageClassification) -> IMessageRemoteAnswer {
        switch classification.messageClass {
        case .userCommand:
            return classification.carriesLink ? .theLinkWasNotFollowed : .theAgentsReply
        case .userSentSomethingElse:
            return .noWordsToRead
        case .ownEcho, .fromSomebodyElse, .couldNotRead, .nothingToRead:
            return .nothing
        }
    }

    /// The one place a class turns into something a person at the Mac reads. **`.ownEcho` is
    /// `.nothing`**, and so is everything else that is not a stranger's row.
    static func localNotice(for classification: IMessageClassification) -> IMessageLocalNotice {
        switch classification.messageClass {
        case .fromSomebodyElse:
            return classification.directionEvidence == .unresolved ? .senderUnresolved : .notFromYou
        case .ownEcho, .userCommand, .userSentSomethingElse, .couldNotRead, .nothingToRead:
            return .nothing
        }
    }
}

// MARK: - The copy

/// Every sentence a person can read about a remote message, in one place.
///
/// **One type, because the drift this prevents is drift between three call sites**: the sheet
/// IM-08d shows, the card IM-17f's status row draws, and the self-test. Three literals in three
/// files is three sentences about one event, and two of them get edited.
///
/// **These are the strings, and they are the ones the lint is really about.**
/// `--selftest-ui-strings` will not catch any of the words this feature must avoid, because it
/// scans `UI/` and reads only five call sites — so the check lives with the copy, in
/// `MessagesClassSelfTest`. The words are `TCC`, `grant`, `attributedBody`, `typedstream`,
/// `payload_data`, `database`, `sqlite`, `watermark`, `probe`, `signature` and a raw tool id.
///
/// **No sentence apologises and none alarms.** `sentSomethingElse` says what arrived, what is
/// missing and the next thing to do, in that order. `notFromYou` names the fact and the absence
/// of action. `pausedReplying` says what happened and what restarts it. The app's own name is
/// in four of the seven and **the Agent's name is in none of them** — the Agent's name reaches a
/// speaking path through `AgentGrounding`, and a spelled-out name is wrong on every Mac where the
/// person renamed it. The app's name is the app's, and three of the four are sentences a person
/// reads about the app rather than about the Agent. None of these strings is ever put in a prompt.
enum IMessageClassifierCopy {
    /// The remote reply for `.userSentSomethingElse`.
    static let sentSomethingElse = "I can tell something arrived, but there are no words with it, so I don't know what to do about it. Send me a message and I'll pick it up."

    /// The card headline for `.fromSomebodyElse` — a stranger, or somebody unidentified.
    static let notFromYou = "That message wasn't from you."

    /// Its second line: what was not done, and the rule in the person's own terms.
    static let notFromYouDetail = "Nothing was done with it. Next Notes only answers messages sent from the number you set up."

    /// The card for an unresolved sender. **A different sentence because the cause is
    /// different**: this row is not a stranger, it is a number this Mac could not check, and it
    /// is a defect to fix rather than a refusal to offer.
    static let senderUnresolved = "A message in your conversation was from a number Next Notes couldn't check against yours, so nothing was done with it."

    /// The remote reply when a link was the whole of a turn's content. It states the limit and
    /// the next action, with no rule number in it.
    static let linkNotFollowed = "I can see the link, but I don't follow links sent from a phone. Tell me what you're after and I'll look for it."

    /// The island card for the breaker: what happened, and what starts it again. Not a
    /// per-row sentence — it belongs to the rate limiter's one raise, not to a message.
    static let pausedReplying = "Next Notes paused replying in case it was talking to itself. Your next message starts it again."

    /// `--imessage-report` only, **never a card**: nothing is actionable, and a card per event
    /// is noise. It says "2 people" and never who, because one address is a count and an
    /// address is not.
    static let conversationGainedAPerson = "Your Messages conversation now has 2 people in it. Next Notes still only answers messages sent from you."

    /// Every sentence above, in one array. The lint case walks this, and it asserts that every
    /// sentence the copy can *return* is a member — so a new literal cannot escape the check by
    /// being reachable from a lookup.
    static let all: [String] = [
        sentSomethingElse,
        notFromYou,
        notFromYouDetail,
        senderUnresolved,
        linkNotFollowed,
        pausedReplying,
        conversationGainedAPerson,
    ]

    /// The sentence that goes back to the phone, if there is one.
    ///
    /// `.theAgentsReply` is `nil` here **on purpose and not by omission**: the reply is IM-13's,
    /// formatted with the name the person chose and produced by the same agent that answers
    /// voice. What IM-08 decides is that a reply is *due*, which is `IMessageClass.remoteSpeaker`.
    static func remoteSentence(for answer: IMessageRemoteAnswer) -> String? {
        switch answer {
        case .nothing, .theAgentsReply: nil
        case .noWordsToRead: sentSomethingElse
        case .theLinkWasNotFollowed: linkNotFollowed
        }
    }

    /// A notice's first line, or `nil` when there is no notice.
    static func headline(for notice: IMessageLocalNotice) -> String? {
        switch notice {
        case .nothing: nil
        case .notFromYou: notFromYou
        case .senderUnresolved: senderUnresolved
        }
    }

    /// A notice's second line, or `nil`. One of the three has none, and inventing a filler
    /// second line is how a card ends up saying "Nothing was done with it." under a headline
    /// about somebody else.
    static func detail(for notice: IMessageLocalNotice) -> String? {
        switch notice {
        case .nothing, .senderUnresolved: nil
        case .notFromYou: notFromYouDetail
        }
    }
}
