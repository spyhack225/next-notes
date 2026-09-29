import Foundation

/// `--selftest-imessage-class` — NextNotes-iMessage IM-08a.
///
/// The classification table, as a pure function: what a remote message is, and what may be said
/// about it. **No Full Disk Access, no paired conversation, no iPhone, no grant, no model, no
/// store, no clock and no ledger** — every case is a value in and a value out, which is the same
/// claim the file under test makes, asserted by the fact that this test can exist at all.
///
/// ## The fourteen cases, and what each one is for
///
/// | # | case | the measurement or rule it pins |
/// |---|---|---|
/// | 1 | `own_echo_says_nothing_for_every_row` | rows 1–2 of the table, and the ledger beating the column: 32 combinations of body × column × sender, and not one of them produces an answer, a card or a turn |
/// | 2 | `user_command_from_this_mac` | rows 3 and 7, and disagreement 4 — the column outranks a handle that says somebody else |
/// | 3 | `user_command_from_the_paired_number_on_a_phone` | row 4: the feature, not an edge case |
/// | 4 | `user_sent_something_else_is_one_sentence` | rows 8 and 9 together: the refusal is the same, only the direction differs |
/// | 5 | `from_somebody_else_is_silent_here_and_one_card_there` | row 6, and the memory gate being unreachable from it |
/// | 6 | `a_sender_that_will_not_resolve_gets_a_different_sentence` | row 5, `DirectionEvidence.unresolved`, and the fail-closed rule on a column/resolver disagreement |
/// | 7 | `an_unreadable_body_is_direction_free_and_keeps_its_reason` | row 10 from both directions, and `MessageDecodeFailure` surviving on the envelope |
/// | 8 | `a_body_with_no_words_and_a_body_with_nothing_say_nothing` | row 11, plus the empty `.text` the decoder cannot produce |
/// | 9 | `a_non_text_balloon_classifies_the_same_however_it_was_named` | the `U+FFFC` route and the `is_audio_message` route, and a bundle id never becoming a string |
/// | 10 | `two_pending_rows_is_a_command` | the ambiguity tiebreak |
/// | 11 | `a_link_does_not_change_the_class_and_is_not_an_instruction` | §4.2: a link is content, not an instruction |
/// | 12 | `no_sentence_names_a_database_a_grant_or_an_app` | the eleven words `--selftest-ui-strings` cannot catch here |
/// | 13 | `the_two_copies_of_one_command_classify_identically` | **IM-01's two-row measurement, as an assertion** |
/// | 14 | `no_class_is_reachable_by_a_row_level_from_me_test` | the negative: the column decides a direction and nothing else |
///
/// ## Why the fixtures are fixtures
///
/// Case 13 uses the **shape** IM-01 measured — two rows, the same 25 characters, the same
/// 202-byte body, opposite `is_from_me` — and a **placeholder sentence of that exact shape**.
/// The real sentence is not committed: `TYPEDSTREAM-NOTES.md` keeps the blob that carries it as
/// a local artefact precisely because it holds a live link and a third party's offer, and a
/// fixture that quoted it would commit somebody's conversation. The case asserts the shape
/// (25 characters, 27 UTF-8 bytes, two row ids, opposite column), so a fixture edited into the
/// wrong shape fails rather than quietly testing something easier.
///
/// ## Red first, and proven able to fail
///
/// The classifier was written last against a seam that reproduced the roadmap's own superseded
/// rule — *"A `from-me` row that matches a pending outbound is ours; everything else is a user
/// command"*, `00-README` §11 — and that build is what `IM-08a-red.txt` records. Every mutation
/// in that file names the assertion it reddened. A test nobody has watched fail is
/// indistinguishable from one that cannot detect a wrong answer.
///
/// ## Blocked, and not counted
///
/// One half of case 13's design claim — *the two copies produce **one** turn* — needs the
/// watcher's guid cache and a database, so it is named on an `IMESSAGE_CLASS_BLOCKED:` line and
/// left out of the number. The classification half runs and is counted; the number is a claim
/// this run can stand behind rather than a denominator that quietly absorbed a skip.
///
/// The final line is `IMESSAGE_CLASS_OK: <n> cases` or `IMESSAGE_CLASS_FAILED: <case>:
/// <reason>`. The per-case diagnostic lines are `IMESSAGE_CLASS_WRONG: …` and the blocked lines
/// are `IMESSAGE_CLASS_BLOCKED: …`; **neither is a verdict token**, so `writeSelfTest` and
/// `Scripts/acceptance.sh` both read past them to the marker last.
@MainActor
enum MessagesClassSelfTest {

    // MARK: - The fixtures

    /// A stand-in for the self-message IM-01 measured: **25 characters, 27 UTF-8 bytes**, two of
    /// them multi-byte — the same arithmetic as the 202-byte body's `0x1b` = 27 length prefix
    /// over a 25-character sentence, and the numbers the decoder's table agrees on. Case 13
    /// asserts all three, so this is a shape and not a sentence.
    static let selfMessage = "réponds-moi s'il te plaît"

    /// The two row ids IM-01 read. Apple's, and opaque; they are here so the case names the
    /// measurement rather than a pair of invented numbers.
    static let firstCopyRowID: Int64 = 55189
    static let secondCopyRowID: Int64 = 55190

    /// A body with a sentence in it, 202 bytes read of which the attribute graph was passed
    /// over — the shape of the real self-message body.
    static func sentenceBody() -> MessageBody {
        .text(selfMessage, discardedBytes: 101)
    }

    /// **An effect**, measured 2026-09-26: a text balloon whose entire string is `U+FFFC`, 314
    /// bytes of which the walk read 77 — so 237 bytes of a third party's attribute graph were
    /// passed over unread, and `balloon_bundle_id` was NULL. The bundle id is `nil` on purpose
    /// and is the reason a class may not require one.
    static func effectBody() -> MessageBody {
        .notText(bundleID: nil, discardedBytes: 237)
    }

    /// **A voice note, by the `is_audio_message` route**: the same `.notText` class, and the
    /// count is the whole body because the walk read none of it. The two differ from
    /// `effectBody()` **only in a number that describes the column rather than the sender**, and
    /// case 9 is that they cannot be told apart from here.
    static func voiceNoteBodyByColumn() -> MessageBody {
        .notText(bundleID: nil, discardedBytes: 466)
    }

    /// The same `.notText` with an id on it, so case 9 can prove an id that exists changes
    /// nothing and reaches no string.
    static let fixtureBundleID = "com.apple.MSMessageExtensionBalloonPlugin"
    static func namedEffectBody() -> MessageBody {
        .notText(bundleID: fixtureBundleID, discardedBytes: 237)
    }

    /// A body this Mac could not read, with a reason that is safe to count and report: a
    /// version byte and a system version, never a byte of the message.
    static let decodeFailure = MessageDecodeFailure.unsupportedStreamVersion(found: 0x05, system: 1000)
    static func unreadableBody() -> MessageBody {
        .unreadable(reason: decodeFailure)
    }

    /// A turn whose words carry a link, and the same turn without one.
    static let linkTurn = "look at https://example.com/pricing for me"
    static let plainTurn = "look at the pricing sheet for me"

    /// The eleven words this feature must never put in front of a person, which
    /// `--selftest-ui-strings` cannot catch here because it scans `UI/` and reads five call
    /// sites. Matched as a **substring, case-insensitively**, which is the strict direction: a
    /// sentence that accidentally contains one is a failure, not a near miss.
    static let forbiddenWords = [
        "tcc", "grant", "attributedbody", "typedstream", "payload_data", "database", "sqlite",
        "watermark", "probe", "signature",
    ]

    // MARK: - The run

    static func run() async -> String {
        var failures: [String] = []
        var blocked: [String] = []
        var caseCount = 0

        func check(_ name: String, _ body: () -> String?) {
            caseCount += 1
            if let problem = body() { failures.append("\(name): \(problem)") }
        }

        /// A case that cannot run at this layer, named and left out of the count.
        func block(_ name: String, _ waits: String) {
            blocked.append("\(name) — \(waits)")
        }

        let bodies: [(String, MessageBody)] = [
            ("sentence", sentenceBody()),
            ("empty sentence", .text("", discardedBytes: 0)),
            ("effect", effectBody()),
            ("unreadable", unreadableBody()),
            ("absent", .absent),
        ]
        let senders: [(String, ResolvedSender)] = [
            ("this Mac", .thisMac),
            ("the paired number", .localNumber),
            ("somebody else", .foreignNumber),
            ("unresolved", .unresolved),
        ]

        // 1 — the loop-breaking case. Every combination, and nothing comes out.
        check("own_echo_says_nothing_for_every_row") {
            for (bodyName, body) in bodies {
                for isFromMe in [true, false] {
                    for (senderName, sender) in senders {
                        let result = IMessageClassifier.classify(body: body, isFromMe: isFromMe,
                                                                 sender: sender, echo: .ownEcho)
                        guard result.messageClass == .ownEcho else {
                            return "\(bodyName) from \(senderName) (is_from_me \(isFromMe)) "
                                + "classified as \(result.messageClass.rawValue)"
                        }
                        guard result.directionEvidence == .notConsulted else {
                            return "\(bodyName) from \(senderName) reported direction "
                                + "\(result.directionEvidence.rawValue) — the ledger decides alone"
                        }
                        guard IMessageClassifier.remoteAnswer(for: result) == .nothing else {
                            return "\(bodyName) from \(senderName) produced a remote answer"
                        }
                        guard IMessageClassifier.localNotice(for: result) == .nothing else {
                            return "\(bodyName) from \(senderName) produced a local notice"
                        }
                        guard result.messageClass.remoteSpeaker == nil else {
                            return "\(bodyName) from \(senderName) can open a turn"
                        }
                    }
                }
            }
            return nil
        }

        // 2 — this Mac. The handle says somebody else and the column still wins, because on
        // this Mac a row dated from this Mac came from this Mac and the handle on an
        // outgoing row is a recipient.
        check("user_command_from_this_mac") {
            let contradictory = IMessageClassifier.classify(body: sentenceBody(), isFromMe: true,
                                                           sender: .foreignNumber, echo: .notOurEcho)
            guard contradictory.messageClass == .userCommand else {
                return "a row the column dates from this Mac was \(contradictory.messageClass.rawValue)"
            }
            guard contradictory.directionEvidence == .thisMac else {
                return "direction was \(contradictory.directionEvidence.rawValue), not the column's"
            }
            let plain = IMessageClassifier.classify(body: sentenceBody(), isFromMe: true,
                                                   sender: .thisMac, echo: .notOurEcho)
            guard plain.messageClass == .userCommand,
                  plain.directionEvidence == .thisMac else {
                return "an ordinary outgoing row was \(plain.messageClass.rawValue)"
            }
            guard plain.messageClass.remoteSpeaker == .userCommand else {
                return "an outgoing command cannot open a turn"
            }
            return nil
        }

        // 3 — the user's own number, on a phone or another Mac. The feature, not an edge case.
        check("user_command_from_the_paired_number_on_a_phone") {
            let result = IMessageClassifier.classify(body: sentenceBody(), isFromMe: false,
                                                     sender: .localNumber, echo: .notOurEcho)
            guard result.messageClass == .userCommand else {
                return "a message from the paired number was \(result.messageClass.rawValue)"
            }
            guard result.directionEvidence == .localNumber else {
                return "direction was \(result.directionEvidence.rawValue)"
            }
            guard result.messageClass.remoteSpeaker == .userCommand,
                  IMessageClassifier.remoteAnswer(for: result) == .theAgentsReply else {
                return "a command from the phone produced no answer"
            }
            return nil
        }

        // 4 — a refusal with each direction. The same `.notText` body, both ways: the
        // refusal is identical and only the direction differs.
        check("user_sent_something_else_is_one_sentence") {
            let mine = IMessageClassifier.classify(body: effectBody(), isFromMe: true,
                                                   sender: .thisMac, echo: .notOurEcho)
            let theirs = IMessageClassifier.classify(body: effectBody(), isFromMe: false,
                                                     sender: .foreignNumber, echo: .notOurEcho)
            guard mine.messageClass == .userSentSomethingElse else {
                return "an effect from the user was \(mine.messageClass.rawValue)"
            }
            guard theirs.messageClass == .fromSomebodyElse else {
                return "an effect from somebody else was \(theirs.messageClass.rawValue)"
            }
            guard IMessageClassifier.remoteAnswer(for: mine) == .noWordsToRead,
                  IMessageClassifier.remoteAnswer(for: theirs) == .nothing else {
                return "the two directions did not answer the same way"
            }
            guard IMessageClassifier.localNotice(for: mine) == .nothing,
                  IMessageClassifier.localNotice(for: theirs) == .notFromYou else {
                return "the two directions did not get the same local treatment"
            }
            let sentence = IMessageClassifierCopy.remoteSentence(
                for: IMessageClassifier.remoteAnswer(for: mine))
            guard let sentence, !sentence.isEmpty else {
                return "the user got no sentence about something arriving with no words"
            }
            guard sentence == IMessageClassifierCopy.sentSomethingElse else {
                return "the sentence is not the one the copy type holds"
            }
            return nil
        }

        // 5 — a stranger. No turn, so nothing can reach `recordUser`, and one card here.
        check("from_somebody_else_is_silent_here_and_one_card_there") {
            let result = IMessageClassifier.classify(body: sentenceBody(), isFromMe: false,
                                                     sender: .foreignNumber, echo: .notOurEcho)
            guard result.messageClass == .fromSomebodyElse else {
                return "a stranger's row was \(result.messageClass.rawValue)"
            }
            guard result.messageClass.remoteSpeaker == nil else {
                return "a stranger's row can open a turn — the memory gate is reachable"
            }
            guard IMessageClassifier.remoteAnswer(for: result) == .nothing else {
                return "a stranger's row was answered on the phone"
            }
            guard IMessageClassifier.localNotice(for: result) == .notFromYou else {
                return "a stranger's row did not produce the one card"
            }
            let headline = IMessageClassifierCopy.headline(for: .notFromYou)
            let detail = IMessageClassifierCopy.detail(for: .notFromYou)
            guard headline == IMessageClassifierCopy.notFromYou,
                  detail == IMessageClassifierCopy.notFromYouDetail else {
                return "the card is not the two lines the copy type holds"
            }
            guard headline != IMessageClassifierCopy.senderUnresolved else {
                return "a stranger and an unresolved sender share one sentence"
            }
            block("from_somebody_else_is_one_card_and_no_memory",
                  "the two halves that need a bridge rather than a function: forty rows "
                  + "collapsing into one card, and `AgentSession.recordUser` never being "
                  + "called — both are IM-08d's cases. What runs here is the gate that "
                  + "makes them true: this class can open no turn, and one row produces "
                  + "exactly one notice")
            return nil
        }

        // 6 — an unidentified sender, and a column that disagrees with the resolver. Both
        // fail closed, and the second one is the case a resolver bug would reach.
        check("a_sender_that_will_not_resolve_gets_a_different_sentence") {
            let unresolved = IMessageClassifier.classify(body: sentenceBody(), isFromMe: false,
                                                         sender: .unresolved, echo: .notOurEcho)
            guard unresolved.messageClass == .fromSomebodyElse else {
                return "an unresolved sender was \(unresolved.messageClass.rawValue)"
            }
            guard unresolved.directionEvidence == .unresolved else {
                return "direction was \(unresolved.directionEvidence.rawValue)"
            }
            guard IMessageClassifier.localNotice(for: unresolved) == .senderUnresolved else {
                return "an unresolved sender did not get its own card"
            }
            guard IMessageClassifierCopy.headline(for: .senderUnresolved)
                    != IMessageClassifierCopy.headline(for: .notFromYou) else {
                return "the two causes share one sentence"
            }
            // The disagreement: a resolver that answered "this Mac" for a row the column
            // says arrived. Fail closed, or a resolver bug becomes a remote command.
            let disagreement = IMessageClassifier.classify(body: sentenceBody(), isFromMe: false,
                                                          sender: .thisMac, echo: .notOurEcho)
            guard disagreement.messageClass == .fromSomebodyElse,
                  disagreement.directionEvidence == .unresolved else {
                return "is_from_me = 0 with a .thisMac sender was "
                    + "\(disagreement.messageClass.rawValue)/\(disagreement.directionEvidence.rawValue)"
            }
            guard IMessageClassifier.remoteAnswer(for: disagreement) == .nothing else {
                return "the disagreement was answered"
            }
            return nil
        }

        // 7 — a body this Mac could not read, from every sender. The direction is not
        // consulted, and the reason stays on the envelope for the canary and the report.
        check("an_unreadable_body_is_direction_free_and_keeps_its_reason") {
            for isFromMe in [true, false] {
                for (_, sender) in senders {
                    let result = IMessageClassifier.classify(body: unreadableBody(),
                                                             isFromMe: isFromMe, sender: sender,
                                                             echo: .notOurEcho)
                    guard result.messageClass == .couldNotRead else {
                        return "an unreadable body from \(sender) was \(result.messageClass.rawValue)"
                    }
                    guard result.directionEvidence == .notConsulted else {
                        return "an unreadable body reported a direction"
                    }
                    guard IMessageClassifier.remoteAnswer(for: result) == .nothing,
                          IMessageClassifier.localNotice(for: result) == .nothing else {
                        return "an unreadable body produced output"
                    }
                    guard result.messageClass.remoteSpeaker == nil else {
                        return "an unreadable body can open a turn"
                    }
                    guard result.carriesLink == false else {
                        return "an unreadable body reported a link it could not read"
                    }
                }
            }
            // The reason is not folded into the class and not lost: the envelope still
            // carries it, which is what the canary's three cases count and what
            // `--imessage-report` prints.
            let envelope = IMessageEnvelope(rowID: 0, guid: "", date: nil, isFromMe: false,
                                            service: "iMessage", body: unreadableBody(),
                                            source: .attributedBody)
            guard envelope.decodeState == .unreadable(reason: decodeFailure),
                  envelope.text == nil else {
                return "the decode reason did not survive on the envelope"
            }
            guard !decodeFailure.description.isEmpty else {
                return "the refusal has no description for a bug report"
            }
            return nil
        }

        // 8 — nothing to read, and no words to read. `.absent` says nothing anywhere, and an
        // empty `.text` is a body with no words rather than a command.
        check("a_body_with_no_words_and_a_body_with_nothing_say_nothing") {
            for isFromMe in [true, false] {
                for (_, sender) in senders {
                    // A row with no body at all: `.nothingToRead` from every direction, and
                    // no sentence on either side of this.
                    let absent = IMessageClassifier.classify(body: .absent, isFromMe: isFromMe,
                                                             sender: sender, echo: .notOurEcho)
                    guard absent.messageClass == .nothingToRead else {
                        return "an absent body from \(sender) was \(absent.messageClass.rawValue)"
                    }
                    guard absent.directionEvidence == .notConsulted,
                          IMessageClassifier.remoteAnswer(for: absent) == .nothing,
                          IMessageClassifier.localNotice(for: absent) == .nothing,
                          absent.messageClass.remoteSpeaker == nil,
                          reachableSentences(for: absent).isEmpty else {
                        return "an absent body from \(sender) was not silent"
                    }
                    // A body whose string is empty: no words, so the same answer as a
                    // `.notText` — one sentence if it is the user, nothing if it is not.
                    let empty = IMessageClassifier.classify(
                        body: .text("", discardedBytes: 0), isFromMe: isFromMe, sender: sender,
                        echo: .notOurEcho)
                    let expected: IMessageClass
                    switch IMessageClassifier.direction(isFromMe: isFromMe, sender: sender) {
                    case .thisMac, .localNumber: expected = .userSentSomethingElse
                    case .foreignNumber, .unresolved: expected = .fromSomebodyElse
                    case .notConsulted: expected = .nothingToRead
                    }
                    guard empty.messageClass == expected else {
                        return "an empty body from \(sender) was \(empty.messageClass.rawValue)"
                    }
                    guard empty.messageClass != .userCommand else {
                        return "an empty body was a command"
                    }
                    if expected == .userSentSomethingElse {
                        guard IMessageClassifier.remoteAnswer(for: empty) == .noWordsToRead,
                              IMessageClassifier.localNotice(for: empty) == .nothing else {
                            return "an empty body from the user did not get the one sentence"
                        }
                    } else {
                        guard IMessageClassifier.remoteAnswer(for: empty) == .nothing else {
                            return "an empty body from somebody else was answered"
                        }
                    }
                }
            }
            return nil
        }

        // 9 — one class, three ways of arriving at it. The source cannot reach this layer,
        // and a bundle id cannot become a string.
        check("a_non_text_balloon_classifies_the_same_however_it_was_named") {
            let routes: [(String, MessageBody)] = [
                ("the U+FFFC walk", effectBody()),
                ("the is_audio_message column", voiceNoteBodyByColumn()),
                ("a named effect", namedEffectBody()),
            ]
            var first: IMessageClassification?
            for (name, body) in routes {
                let result = IMessageClassifier.classify(body: body, isFromMe: false,
                                                         sender: .localNumber, echo: .notOurEcho)
                if let first {
                    guard result == first else {
                        return "\(name) classified differently from the first route"
                    }
                } else {
                    first = result
                }
                guard result.messageClass == .userSentSomethingElse else {
                    return "\(name) was \(result.messageClass.rawValue)"
                }
            }
            // The id is on the body and reaches no sentence, in either direction.
            for sender in [ResolvedSender.localNumber, .foreignNumber] {
                let named = IMessageClassifier.classify(body: namedEffectBody(), isFromMe: false,
                                                        sender: sender, echo: .notOurEcho)
                let anonymous = IMessageClassifier.classify(body: effectBody(), isFromMe: false,
                                                           sender: sender, echo: .notOurEcho)
                guard named == anonymous else {
                    return "naming the balloon changed the answer"
                }
                for sentence in reachableSentences(for: named) {
                    guard !sentence.contains(fixtureBundleID) else {
                        return "a bundle id reached a sentence"
                    }
                }
            }
            return nil
        }

        // 10 — two pending rows matched one row. It is a command.
        check("two_pending_rows_is_a_command") {
            let ambiguous = IMessageClassifier.classify(body: sentenceBody(), isFromMe: true,
                                                        sender: .thisMac, echo: .ambiguous)
            guard ambiguous.messageClass == .userCommand else {
                return "an ambiguous match was \(ambiguous.messageClass.rawValue) — a real "
                    + "request is lost silently"
            }
            guard ambiguous.messageClass.remoteSpeaker == .userCommand else {
                return "an ambiguous match cannot open a turn"
            }
            // And the same row with a definite match is the echo, so the tiebreak is the
            // only thing that moved it — which is the point: it moves toward the user only.
            let definite = IMessageClassifier.classify(body: sentenceBody(), isFromMe: true,
                                                       sender: .thisMac, echo: .ownEcho)
            guard definite.messageClass == .ownEcho else {
                return "a definite match was not an echo, so nothing is left to break the loop"
            }
            return nil
        }

        // 11 — a link is content. The class is the same with and without one, and no
        // sentence in the feature is a fetch.
        check("a_link_does_not_change_the_class_and_is_not_an_instruction") {
            let linked = IMessageClassifier.classify(body: .text(linkTurn, discardedBytes: 0),
                                                     isFromMe: false, sender: .localNumber,
                                                     echo: .notOurEcho)
            let plain = IMessageClassifier.classify(body: .text(plainTurn, discardedBytes: 0),
                                                    isFromMe: false, sender: .localNumber,
                                                    echo: .notOurEcho)
            guard linked.messageClass == plain.messageClass,
                  linked.directionEvidence == plain.directionEvidence else {
                return "a link in the words changed the class"
            }
            guard linked.carriesLink, !plain.carriesLink else {
                return "carriesLink was \(linked.carriesLink)/\(plain.carriesLink)"
            }
            guard IMessageClassifier.remoteAnswer(for: linked) == .theLinkWasNotFollowed,
                  IMessageClassifier.remoteAnswer(for: plain) == .theAgentsReply else {
                return "the link did not reach the one sentence about links"
            }
            guard IMessageClassifierCopy.remoteSentence(for: .theLinkWasNotFollowed)
                    == IMessageClassifierCopy.linkNotFollowed else {
                return "the link sentence is not the one the copy type holds"
            }
            // Link-only versus link-among-words, which is the sentence's own selector.
            guard IMessageClassifier.isOnlyALink(.text("https://example.com/a", discardedBytes: 0)),
                  !IMessageClassifier.isOnlyALink(.text(linkTurn, discardedBytes: 0)),
                  !IMessageClassifier.isOnlyALink(.text(plainTurn, discardedBytes: 0)) else {
                return "link-only detection is wrong"
            }
            // The negative that matters: a link in somebody else's row is still not an
            // instruction, and an echo of a link is still silence.
            let stranger = IMessageClassifier.classify(body: .text(linkTurn, discardedBytes: 0),
                                                      isFromMe: false, sender: .foreignNumber,
                                                      echo: .notOurEcho)
            guard stranger.carriesLink,
                  IMessageClassifier.remoteAnswer(for: stranger) == .nothing,
                  IMessageClassifier.localNotice(for: stranger) == .notFromYou else {
                return "a stranger's link was treated as something to act on"
            }
            let echo = IMessageClassifier.classify(body: .text(linkTurn, discardedBytes: 0),
                                                   isFromMe: true, sender: .thisMac, echo: .ownEcho)
            guard echo.carriesLink,
                  IMessageClassifier.remoteAnswer(for: echo) == .nothing else {
                return "an echo of a link produced output"
            }
            for sentence in reachableSentences(for: linked) + reachableSentences(for: stranger) {
                guard !sentence.contains("://") else {
                    return "a sentence carries a URL"
                }
            }
            return nil
        }

        // 12 — the eleven words, plus the app's own lint, plus a bundle id, plus the Agent's
        // name, across every sentence the copy can return and the ones only it holds.
        check("no_sentence_names_a_database_a_grant_or_an_app") {
            guard Set(IMessageClassifierCopy.all).count == IMessageClassifierCopy.all.count else {
                return "the copy table has a duplicate, so one of them is unreachable"
            }
            for sentence in IMessageClassifierCopy.all {
                if let problem = copyProblem(sentence) { return problem }
            }
            // Completeness: anything the lookups can return is in `all`, so a new literal
            // cannot escape the lint by being reachable.
            var reachable: [String] = []
            for answer in [IMessageRemoteAnswer.nothing, .theAgentsReply, .noWordsToRead,
                           .theLinkWasNotFollowed] {
                if let sentence = IMessageClassifierCopy.remoteSentence(for: answer) {
                    reachable.append(sentence)
                }
            }
            for notice in [IMessageLocalNotice.nothing, .notFromYou, .senderUnresolved] {
                for sentence in [IMessageClassifierCopy.headline(for: notice),
                                 IMessageClassifierCopy.detail(for: notice)] {
                    if let sentence { reachable.append(sentence) }
                }
            }
            for sentence in reachable {
                guard IMessageClassifierCopy.all.contains(sentence) else {
                    return "a reachable sentence is not in the lint's table"
                }
                if let problem = copyProblem(sentence) { return problem }
            }
            return nil
        }

        // 13 — IM-01's two-row measurement, as an assertion.
        check("the_two_copies_of_one_command_classify_identically") {
            guard selfMessage.count == 25 else {
                return "the fixture is \(selfMessage.count) characters, not the measured 25"
            }
            guard selfMessage.utf8.count == 27 else {
                return "the fixture is \(selfMessage.utf8.count) bytes, not the measured 27"
            }
            // Row 55189, is_from_me = 1. Row 55190, is_from_me = 0, the same sentence and
            // the same body. Neither is in the ledger: the user typed it on their phone, so
            // both are commands and neither is an echo.
            let copies: [(rowID: Int64, isFromMe: Bool, sender: ResolvedSender)] = [
                (firstCopyRowID, true, .thisMac),
                (secondCopyRowID, false, .localNumber),
            ]
            let classified = copies.map {
                (rowID: $0.rowID,
                 result: IMessageClassifier.classify(body: sentenceBody(), isFromMe: $0.isFromMe,
                                                     sender: $0.sender, echo: .notOurEcho))
            }
            for (rowID, result) in classified {
                guard result.messageClass == .userCommand else {
                    return "row \(rowID) was \(result.messageClass.rawValue)"
                }
                guard result.carriesLink == false,
                      result.messageClass.remoteSpeaker == .userCommand,
                      IMessageClassifier.remoteAnswer(for: result) == .theAgentsReply,
                      IMessageClassifier.localNotice(for: result) == .nothing else {
                    return "row \(rowID) did not produce one turn's worth of answer"
                }
            }
            let outgoing = classified[0].result
            let incoming = classified[1].result
            // **The class is the same and the direction is not**, and that difference is the
            // whole finding: a filter written on the column finds one copy and misses the
            // other, and which copy it gets is not something the row decides.
            guard outgoing.messageClass == incoming.messageClass,
                  outgoing.directionEvidence != incoming.directionEvidence,
                  outgoing.directionEvidence == .thisMac,
                  incoming.directionEvidence == .localNumber else {
                return "the copies were not told apart by direction, so this case is not "
                    + "testing the two-row shape"
            }
            // The same two rows with the ledger claiming them are our own: a classifier that
            // reached for the column first would find exactly one copy and miss the other.
            for copy in copies {
                let echo = IMessageClassifier.classify(body: sentenceBody(),
                                                       isFromMe: copy.isFromMe,
                                                       sender: copy.sender, echo: .ownEcho)
                guard echo.messageClass == .ownEcho else {
                    return "matched row \(copy.rowID) (is_from_me \(copy.isFromMe)) was "
                        + "\(echo.messageClass.rawValue)"
                }
            }
            block("the_two_copies_produce_one_turn",
                  "the second half of the claim needs IM-06's guid cache driven by a real "
                  + "watcher over a database, and a pure classifier has neither; the "
                  + "classification half above ran and is counted")
            return nil
        }

        // 14 — the negative. The column decides a direction and nothing else, so no class
        // is reachable by a row-level `is_from_me` test.
        check("no_class_is_reachable_by_a_row_level_from_me_test") {
            for (bodyName, body) in bodies {
                for (_, sender) in senders {
                    let outgoing = IMessageClassifier.classify(body: body, isFromMe: true,
                                                              sender: sender, echo: .notOurEcho)
                    let incoming = IMessageClassifier.classify(body: body, isFromMe: false,
                                                               sender: sender, echo: .notOurEcho)
                    // The safety half, stated first: the column can only add the user. A row
                    // that is the user's on a `false` column — the person texting from their
                    // own number, which is the feature — is the user's on a `true` column
                    // too, so there is no path by which the column loses a real command.
                    if incoming.messageClass == .userCommand
                        || incoming.messageClass == .userSentSomethingElse {
                        guard outgoing.messageClass == .userCommand
                                || outgoing.messageClass == .userSentSomethingElse else {
                            return "\(bodyName) with \(sender): the column turned the user's own "
                                + "row into \(outgoing.messageClass.rawValue)"
                        }
                    }
                    if outgoing.messageClass != incoming.messageClass {
                        // **The only reason a column may change a class**, and it is the one
                        // the design's table gives it: the column says *this Mac sent it*.
                        // It can therefore only ever make a row the user's — never turn the
                        // user's row into somebody else's, and never identify a self-message,
                        // which is the ledger's job alone. Any other difference is a class
                        // decided by the column, and IM-01's two-row measurement is what
                        // makes that error twice.
                        guard outgoing.directionEvidence == .thisMac else {
                            return "\(bodyName) with \(sender) did not take the column's direction"
                        }
                        guard sender != .localNumber else {
                            return "\(bodyName) with a sender that already said the user changed"
                        }
                        guard incoming.messageClass == .fromSomebodyElse else {
                            return "\(bodyName) with \(sender) turned into "
                                + "\(incoming.messageClass.rawValue) on a true column"
                        }
                        if sender == .thisMac {
                            guard incoming.directionEvidence == .unresolved else {
                                return "a .thisMac sender on a false column was believed"
                            }
                        }
                        continue
                    }
                    // Same class either way: the column moved the *direction* and nothing
                    // else, and the direction is the one answer the two signals are allowed
                    // to disagree about. A class that never asked is not affected at all.
                    guard outgoing.directionEvidence == .notConsulted
                            || outgoing.directionEvidence
                                == IMessageClassifier.direction(isFromMe: true, sender: sender)
                    else {
                        return "\(bodyName) with \(sender) reported "
                            + "\(outgoing.directionEvidence.rawValue) rather than the column's"
                    }
                    guard IMessageClassifier.remoteAnswer(for: outgoing)
                            == IMessageClassifier.remoteAnswer(for: incoming) else {
                        return "\(bodyName) with \(sender) answered differently by column"
                    }
                    guard IMessageClassifier.localNotice(for: outgoing).isSameCard(
                        as: IMessageClassifier.localNotice(for: incoming)) else {
                        return "\(bodyName) with \(sender) showed a different card by column"
                    }
                }
            }
            // And the refusals never consult the column at all: same class, same silence,
            // whatever it says.
            for (bodyName, body) in [("unreadable", unreadableBody()),
                                     ("absent", MessageBody.absent)] {
                for isFromMe in [true, false] {
                    let result = IMessageClassifier.classify(body: body, isFromMe: isFromMe,
                                                             sender: .localNumber,
                                                             echo: .notOurEcho)
                    guard result.directionEvidence == .notConsulted else {
                        return "a \(bodyName) body consulted the column"
                    }
                }
            }
            // The claim the two-row case exists for, stated as an invariant: a matched echo
            // is an echo from **every** direction and **every** body, so the column can
            // never be what identifies a self-message.
            for (bodyName, body) in bodies {
                for isFromMe in [true, false] {
                    for (_, sender) in senders {
                        let matched = IMessageClassifier.classify(body: body, isFromMe: isFromMe,
                                                                 sender: sender, echo: .ownEcho)
                        guard matched.messageClass == .ownEcho else {
                            return "a matched \(bodyName) row was \(matched.messageClass.rawValue)"
                        }
                    }
                }
            }
            return nil
        }

        // MARK: - IM-08c: membership and direction

        let local = RemoteIdentity(canonical: "+15551234567")

        // 1. A chat whose only participant is the local number is the self channel.
        check("a chat with only the local number is the self channel") {
            SelfChatMembershipResolver.resolve(participants: ["+15551234567"], localIdentity: local) == .isSelf
                ? nil : "got \(SelfChatMembershipResolver.resolve(participants: ["+15551234567"], localIdentity: local))"
        }

        // 2. A chat with two participants is not.
        check("a chat with two participants is not the self channel") {
            SelfChatMembershipResolver.resolve(participants: ["+15551234567", "+15559876543"], localIdentity: local) == .isNotSelf
                ? nil : "got \(SelfChatMembershipResolver.resolve(participants: ["+15551234567", "+15559876543"], localIdentity: local))"
        }

        // 3. A group that was only the user stays paired after a second handle appears.
        check("a group that was only the user stays paired after a second handle appears") {
            SelfChatMembershipResolver.resolve(participants: ["+15551234567", "+15559876543"], localIdentity: local) == .isNotSelf
                ? nil : "got \(SelfChatMembershipResolver.resolve(participants: ["+15551234567", "+15559876543"], localIdentity: local))"
        }

        // 4. cannotTell when the participants join is absent.
        check("cannotTell when the participants join is absent") {
            SelfChatMembershipResolver.resolve(participants: [], localIdentity: local) == .cannotTell
                ? nil : "got \(SelfChatMembershipResolver.resolve(participants: [], localIdentity: local))"
        }

        // 5. A row whose chat cannot be read is cannotTell.
        check("a row whose chat cannot be read is cannotTell") {
            SelfChatMembershipResolver.resolveUnknown() == .cannotTell
                ? nil : "got \(SelfChatMembershipResolver.resolveUnknown())"
        }

        // 6. The three sender rows of §2.2.
        check("a sender handle that matches the local identity is .localNumber") {
            IMessageDirectionResolver.resolve(senderHandle: "+15551234567", localIdentity: local) == .localNumber
                ? nil : "got \(IMessageDirectionResolver.resolve(senderHandle: "+15551234567", localIdentity: local))"
        }
        check("a sender handle that does not match is .foreignNumber") {
            IMessageDirectionResolver.resolve(senderHandle: "+15559876543", localIdentity: local) == .foreignNumber
                ? nil : "got \(IMessageDirectionResolver.resolve(senderHandle: "+15559876543", localIdentity: local))"
        }
        check("a nil sender handle is .unresolved") {
            IMessageDirectionResolver.resolve(senderHandle: nil, localIdentity: local) == .unresolved
                ? nil : "got \(IMessageDirectionResolver.resolve(senderHandle: nil, localIdentity: local))"
        }

        // 7. unresolved fails closed.
        check("unresolved fails closed when the local identity is unknown") {
            IMessageDirectionResolver.resolve(senderHandle: "+15551234567", localIdentity: nil) == .unresolved
                ? nil : "got \(IMessageDirectionResolver.resolve(senderHandle: "+15551234567", localIdentity: nil))"
        }

        // 8. A normalised comparison that would match a suffix of the local number does not.
        check("a suffix of the local number does not match") {
            IMessageDirectionResolver.resolve(senderHandle: "5551234567", localIdentity: local) == .foreignNumber
                ? nil : "got \(IMessageDirectionResolver.resolve(senderHandle: "5551234567", localIdentity: local))"
        }

        // 9. A formatted variant of the local number matches.
        check("a formatted variant of the local number matches") {
            IMessageDirectionResolver.resolve(senderHandle: "+1 (555) 123-4567", localIdentity: local) == .localNumber
                ? nil : "got \(IMessageDirectionResolver.resolve(senderHandle: "+1 (555) 123-4567", localIdentity: local))"
        }

        // Blocked first, then the wrong lines, then the marker: `writeSelfTest` writes this in a
        // single call while `print` goes through a buffered stream, so the verdict has to be in
        // the returned string to be the last thing a reader sees.
        var lines = blocked.map { "IMESSAGE_CLASS_BLOCKED: \($0)" }
        lines.append(contentsOf: failures.map { "IMESSAGE_CLASS_WRONG: \($0)" })
        lines.append(failures.isEmpty
            ? "IMESSAGE_CLASS_OK: \(caseCount) cases"
            : "IMESSAGE_CLASS_FAILED: \(failures[0])")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Every sentence that could be shown to a person for this classification, in either place.
    static func reachableSentences(for classification: IMessageClassification) -> [String] {
        var sentences: [String] = []
        if let sentence = IMessageClassifierCopy.remoteSentence(
            for: IMessageClassifier.remoteAnswer(for: classification)) {
            sentences.append(sentence)
        }
        let notice = IMessageClassifier.localNotice(for: classification)
        for sentence in [IMessageClassifierCopy.headline(for: notice),
                         IMessageClassifierCopy.detail(for: notice)] {
            if let sentence { sentences.append(sentence) }
        }
        return sentences
    }

    /// One lint problem in one sentence, or nil. Substring matching, case-insensitive, and the
    /// app's own `UIStringsLint` rules on top — which is what a raw tool id and a schema key are
    /// checked by, rather than by a second list here.
    private static func copyProblem(_ sentence: String) -> String? {
        let lowered = sentence.lowercased()
        for word in forbiddenWords where lowered.contains(word) {
            return "a sentence contains the word \"\(word)\""
        }
        for token in UIStringsLint.forbiddenTokens(in: sentence) {
            return "a sentence contains \(token)"
        }
        if UIStringsLint.spellsTheAgentName(in: sentence) {
            return "a sentence spells the Agent's name"
        }
        if sentence.contains(fixtureBundleID) || sentence.contains("com.apple") {
            return "a sentence contains an app identifier"
        }
        if sentence.contains("://") || sentence.lowercased().contains("www.") {
            return "a sentence contains a link"
        }
        if sentence.contains("chat.db") || sentence.contains("Messages.app") {
            return "a sentence names a file on this Mac"
        }
        return nil
    }
}

extension IMessageLocalNotice {
    /// Whether two notices would draw the same card. `.nothing` is its own answer: the question
    /// case 14 asks is whether the column changed what a person sees, and "nothing" is a card
    /// too.
    func isSameCard(as other: IMessageLocalNotice) -> Bool {
        switch (self, other) {
        case (.nothing, .nothing), (.notFromYou, .notFromYou),
             (.senderUnresolved, .senderUnresolved):
            true
        default: false
        }
    }
}
