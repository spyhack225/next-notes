import Foundation

/// `--selftest-function-calls [engine-directory]`
///
/// Answers one question from a terminal: **does saying something out loud turn into the
/// right call, with no argument anybody invented?**
///
/// It fails when no backend produced a call at all. That matters more here than usual: every
/// other check in this file is a rule about calls, and a run where nothing generated one
/// would pass all of them while proving nothing — which is the failure mode AGENTS.md calls
/// "a probe that passes anyway is worse than none".
///
/// The optional argument is a directory holding `needle3-macos-arm64` and `needle3.cact`,
/// which is how the real engine gets exercised on a machine where nobody has asked for the
/// download. Without it, the probe uses whatever is in Application Support, and says plainly
/// when that is nothing.
@MainActor
enum FunctionCallSelfTest {
    /// A sentence and what should come of it.
    struct Fixture: Sendable {
        var name: String
        /// What the microphone heard.
        var utterance: String
        /// What was said before it. Values found here are grounded too.
        var window: String = ""
        /// The tool that should be proposed, or nil when nothing should be.
        var expectedTool: String?
        /// Arguments that must be present with exactly these values.
        var expectedArguments: [String: String] = [:]
        /// Arguments that must come back **missing** rather than filled in. The whole point.
        var expectedMissing: [String] = []
    }

    /// Every fixture is a sentence somebody would actually say.
    static let fixtures: [Fixture] = [
        Fixture(
            name: "address said out loud",
            utterance: "Can you email sarah@acme.com the Q3 deck and say thanks for the call?",
            expectedTool: "send_email",
            expectedArguments: ["to": "sarah@acme.com"]
        ),
        Fixture(
            // The case this feature exists for. There is no address anywhere, and a model
            // asked to send an email will write one that looks completely real.
            name: "no address anywhere",
            utterance: "Send Marcus the updated pricing sheet.",
            expectedTool: "send_email",
            expectedMissing: ["to"]
        ),
        Fixture(
            name: "address said a minute earlier",
            utterance: "Alright, send her the deck then.",
            window: "You: Sarah is joining late.\nOthers: Her address is sarah@acme.com.",
            expectedTool: "send_email"
        ),
        Fixture(
            name: "ordinary conversation",
            utterance: "Yeah, I totally agree, that makes a lot of sense to me.",
            expectedTool: nil
        ),

        // MARK: Sentences with no answer in this catalogue
        //
        // The first is verbatim from `agent-audit.jsonl`, 2026-09-20T20:45:00Z. The user said
        // it to the assistant; the assistant's own path ran `browser.navigate`; and in
        // parallel this watcher proposed `append_doc` with the sentence itself as both the
        // document and the text, which was then approved. Every sibling below is the same
        // shape: a request for a tool this catalogue deliberately does not contain — computer
        // control, the browser, the file system, a read. The only correct answer to all of
        // them is silence, and a nearest neighbour is not a lesser version of that answer.
        Fixture(
            name: "the browser command that started this",
            utterance: "You open Google Chrome and go to youtube.com.",
            expectedTool: nil
        ),
        Fixture(
            name: "browser command, as a person would say it",
            utterance: "Open Google Chrome and go to youtube",
            expectedTool: nil
        ),
        Fixture(
            name: "a folder on this Mac",
            utterance: "Open my Next Notes folder",
            expectedTool: nil
        ),
        Fixture(
            name: "media control",
            utterance: "Play some music, something quiet",
            expectedTool: nil
        ),
        Fixture(
            name: "a question about the diary",
            // Contains the word "calendar", which is exactly why it is here: the cue that
            // would legitimately reach `create_event` is present, and nothing is being asked
            // to happen. A read is not in the catalogue and a question is not a request.
            utterance: "What's on my calendar this afternoon?",
            expectedTool: nil
        ),
        Fixture(
            name: "a search somebody asked for out loud",
            utterance: "Search for the pricing page and click the first result",
            expectedTool: nil
        ),
    ]

    @discardableResult
    static func run() async -> Bool {
        var failures: [String] = []
        /// Calls produced by a model that actually ran — Needle, or the fallback against a
        /// real resolved provider. Nothing scripted may touch this.
        ///
        /// It is kept apart from the scripted fixtures for one reason: the verdict below
        /// depends on it, and a verdict fed by a hardcoded JSON literal is satisfied on a
        /// machine where no inference happened at all. That is the exact failure this file's
        /// own header calls "a probe that passes anyway is worse than none", and it was true
        /// of this counter.
        var modelCalls = 0
        /// Calls produced by a scripted provider. These prove decoding, schema filtering and
        /// grounding; they prove nothing about a model, so they prove nothing about the run.
        var scriptedCalls = 0

        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // MARK: The grounding rule, on its own
        //
        // These run without a model because they are the rule the whole feature rests on,
        // and a rule that is only exercised through a 121M model is a rule nobody can debug.
        let said = FunctionCallGrounding.normalize(
            "Send the Q3 deck to sarah@acme.com before Friday"
        )
        check(
            "a spoken address was treated as invented",
            FunctionCallGrounding.isGrounded("sarah@acme.com", in: said)
        )
        check(
            "an invented address was accepted",
            !FunctionCallGrounding.isGrounded("marcus.chen@proton.me", in: said)
        )
        check(
            "a near-miss address was accepted",
            !FunctionCallGrounding.isGrounded("sarah@acme.co", in: said)
        )
        check(
            "a rewritten subject line was refused",
            FunctionCallGrounding.isGrounded("Q3 deck", in: said)
        )
        check(
            "a subject with no support in the words was accepted",
            !FunctionCallGrounding.isGrounded("Quarterly budget approval", in: said)
        )
        check(
            "a date near a time expression was refused",
            FunctionCallGrounding.isGrounded("2026-09-25T09:00:00Z", in: said)
        )
        check(
            "a date with nothing time-shaped said was accepted",
            !FunctionCallGrounding.isGrounded(
                "2026-09-25T09:00:00Z",
                in: FunctionCallGrounding.normalize("Send the deck to sarah@acme.com")
            )
        )
        check(
            "an accented name failed to match its decomposed form",
            FunctionCallGrounding.isGrounded(
                "Bj\u{00f6}rnsson",
                in: FunctionCallGrounding.normalize("ask Bjo\u{0308}rnsson about it")
            )
        )

        // MARK: Shape, which grounding alone does not cover
        //
        // Every one of these is a value Needle actually produced against the real
        // catalogue on 2026-09-19, or the shape of one.
        check(
            "a first name was accepted as an email address",
            !FunctionCallGrounding.hasShape("Marcus", .email)
        )
        check(
            "an email address was refused",
            FunctionCallGrounding.hasShape("sarah@acme.com", .email)
        )
        check(
            "a list of addresses was refused",
            FunctionCallGrounding.hasShape("sarah@acme.com, bo@example.io", .email)
        )
        check(
            "a list with one real address and one name was accepted",
            !FunctionCallGrounding.hasShape("sarah@acme.com, Marcus", .email)
        )
        check(
            "an address with no domain was accepted",
            !FunctionCallGrounding.hasShape("sarah@acme", .email)
        )
        check(
            "\u{201c}tomorrow at three\u{201d} was accepted as a calendar time",
            !FunctionCallGrounding.hasShape("tomorrow at three", .dateTime)
        )
        check(
            "a real timestamp was refused",
            FunctionCallGrounding.hasShape("2026-09-21T15:00:00-04:00", .dateTime)
        )
        check(
            "a subject line was held to a shape it does not have",
            FunctionCallGrounding.hasShape("Anything at all", .text)
        )
        // The measured value from 2026-09-20: `append_doc(document_id: <the utterance>)`.
        // `document_id` reaches `docs +write --document` as an opaque handle, so a sentence
        // is not an approximate answer for it, it is a different kind of thing.
        check(
            "a whole sentence was accepted as a document id",
            !FunctionCallGrounding.hasShape(
                "You open Google Chrome and go to youtube.com", .identifier
            )
        )
        check(
            "a document title was accepted as a document id",
            !FunctionCallGrounding.hasShape("Q3 planning notes", .identifier)
        )
        check(
            "a real document id was refused",
            FunctionCallGrounding.hasShape(
                "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms", .identifier
            )
        )
        check(
            "document_id was not recognised as an identifier field",
            FunctionCallCatalogue.shape(of: .init(
                name: "document_id", description: "The document to append to."
            )) == .identifier
        )

        // MARK: The echo rule
        //
        // A command is never the content of the thing it commands. This is the rule that
        // catches the case where every other rule reads green: the value *is* the sentence,
        // so it is perfectly grounded, and the model had nothing and filled the field with
        // the prompt.
        let command = "You open Google Chrome and go to youtube.com."
        check(
            "THE USER'S OWN COMMAND SURVIVED AS DOCUMENT CONTENT",
            FunctionCallGrounding.isEcho(command, of: command)
        )
        check(
            "the command survived with the pronoun trimmed off",
            FunctionCallGrounding.isEcho("Open Google Chrome and go to youtube.com", of: command)
        )
        check(
            "a legitimate rewritten subject was mistaken for an echo",
            !FunctionCallGrounding.isEcho(
                "Updated pricing sheet", of: "Send Marcus the updated pricing sheet."
            )
        )
        check(
            "a legitimate body was mistaken for an echo",
            !FunctionCallGrounding.isEcho(
                "Here is the updated pricing sheet.",
                of: "Send Marcus the updated pricing sheet."
            )
        )
        check(
            "a short utterance tripped the echo rule on anything at all",
            !FunctionCallGrounding.isEcho("Deck", of: "send it")
        )

        // MARK: Abstention
        //
        // Four rules, checked one at a time, because the point of having four is that no
        // single prompt change can take them all out at once.
        for utterance in [
            "You open Google Chrome and go to youtube.com.",
            "Open Google Chrome and go to youtube",
            "Open my Next Notes folder",
            "Play some music, something quiet",
            "Click the sign in button",
            "Search for the pricing page and click the first result",
        ] {
            check(
                "A COMMAND TO THE COMPUTER WAS TREATED AS A CATALOGUE REQUEST: "
                    + "\u{201c}\(utterance)\u{201d}",
                FunctionCallRelevance.isDeviceCommand(utterance)
            )
        }
        for utterance in [
            "Can you email sarah@acme.com the Q3 deck?",
            "Send Marcus the updated pricing sheet.",
            "Put the review in the diary for Thursday morning",
            "Open the planning doc and add a line about the rollout",
        ] {
            check(
                "a real request was refused as a computer command: \u{201c}\(utterance)\u{201d}",
                !FunctionCallRelevance.isDeviceCommand(utterance)
            )
        }
        check(
            "a question about the calendar was treated as a request to create an event",
            FunctionCallRelevance.isInformationalQuestion("What's on my calendar this afternoon?")
        )
        check(
            "\u{201c}Can you\u{2026}\u{201d} was thrown away as a question",
            !FunctionCallRelevance.isInformationalQuestion(
                "Can you email sarah@acme.com the Q3 deck?"
            )
        )
        check(
            "a question that also asks for a send was refused",
            FunctionCallRelevance.asksToWrite("What's her address, and can you send her the deck?")
        )
        check(
            "append_doc could be proposed for a sentence with no document in it",
            !FunctionCallRelevance.hasIntent(
                for: "append_doc", in: "You open Google Chrome and go to youtube.com."
            )
        )
        check(
            "append_doc could not be proposed for a sentence about a document",
            FunctionCallRelevance.hasIntent(
                for: "append_doc", in: "Add that to the planning doc"
            )
        )
        check(
            "send_email needs neither a send nor an email to be proposed",
            !FunctionCallRelevance.hasIntent(for: "send_email", in: "Let's talk about it Tuesday")
        )
        check(
            "send_email was not recognised in a plain send",
            FunctionCallRelevance.hasIntent(for: "send_email", in: "Send Marcus the pricing sheet")
        )
        check(
            "a continuation lost the vocabulary its window supplied",
            FunctionCallRelevance.hasIntent(
                for: "send_email",
                in: "Alright, her then.",
                or: "You: Sarah is joining late.\nOthers: Email her the deck."
            )
        )
        check(
            "the abstention tool would be executable",
            AgentToolRegistry.shared.tool(named: FunctionCallRelevance.abstentionToolID) == nil
        )

        // MARK: The catalogue
        let catalogue = FunctionCallCatalogue.current()
        check("the tool catalogue was empty", !catalogue.isEmpty)
        check(
            "the catalogue offered a read tool to a background listener",
            catalogue.allSatisfy { descriptor in
                (AgentToolRegistry.shared.tool(named: descriptor.id)?.risk ?? .observe)
                    >= FunctionCallCatalogue.minimumRisk
            }
        )
        check(
            "the catalogue exceeded what fits in the model's context",
            catalogue.count <= FunctionCallCatalogue.maxTools
        )
        check(
            "the catalogue offered a shell, file or computer-control tool to overheard speech",
            catalogue.allSatisfy { descriptor in
                guard let tool = AgentToolRegistry.shared.tool(named: descriptor.id) else { return false }
                return FunctionCallCatalogue.allowedNamespaces.contains(tool.namespace)
            }
        )
        check(
            "send_email was not offered",
            catalogue.contains { $0.id == "send_email" }
        )
        // The catalogue as the model actually sees it: with somewhere to say no. Before this
        // existed, "which of these eight?" was a question with no correct answer for most
        // sentences, and the model answered it anyway.
        check(
            "the abstention tool is not offered to the model",
            FunctionCallRelevance.wireTools(for: catalogue)
                .contains { $0.id == FunctionCallRelevance.abstentionToolID }
        )
        check(
            "the abstention tool arrives with arguments to fill in",
            FunctionCallRelevance.abstention.parameters.isEmpty
        )
        check(
            "adding the abstention tool twice would grow the list",
            FunctionCallRelevance.wireTools(
                for: FunctionCallRelevance.wireTools(for: catalogue)
            ).count == catalogue.count + 1
        )
        SelfTest.diagnostic(
            "FUNCTION_CALLS_CATALOGUE: \(catalogue.map(\.id).joined(separator: ", "))"
        )

        // MARK: The fallback's grammar
        let grammar = LocalModelFunctionCallProposer.grammar(for: catalogue)
        let problems = grammar.structuralProblems()
        check("the fallback grammar does not parse: \(problems.joined(separator: "; "))", problems.isEmpty)

        // MARK: The fallback, on a scripted answer
        //
        // The scripted string stands in for the model, not for the pipeline: decoding,
        // schema filtering and grounding are the real code, and the grammar is asserted to
        // accept the fixture so the script cannot drift into something no model could emit.
        let invented = """
        {"calls":[{"tool":"send_email","arguments":[{"name":"to","value":"marcus.chen@proton.me"},\
        {"name":"subject","value":"Updated pricing sheet"},{"name":"body","value":"Here is the updated pricing sheet."}],\
        "quote":"Send Marcus the updated pricing sheet","confidence":92}]}
        """
        check("the grammar rejects its own fixture", grammar.matches(invented))

        let fallback = LocalModelFunctionCallProposer { _, _, _ in invented }
        let fallbackRequest = FunctionCallRequest(
            utterance: "Send Marcus the updated pricing sheet.",
            tools: catalogue
        )
        var fallbackCalls: [ProposedFunctionCall] = []
        do {
            fallbackCalls = try await fallback.propose(fallbackRequest)
        } catch {
            failures.append("the fallback proposer threw: \(error.localizedDescription)")
        }
        scriptedCalls += fallbackCalls.count
        check("the fallback proposed nothing for a plain request", !fallbackCalls.isEmpty)
        if let call = fallbackCalls.first {
            check("the fallback named the wrong tool", call.toolID == "send_email")
            check(
                "THE FALLBACK INVENTED AN EMAIL ADDRESS: \(call.arguments["to"] ?? "")",
                call.arguments["to"] == nil
            )
            check(
                "the fallback did not report the address as missing",
                call.missingArguments.contains("to")
            )
            check(
                "the fallback threw away a subject it was entitled to write",
                call.arguments["subject"] != nil
            )
            check("a call with a missing argument claimed to be complete", !call.isComplete)
            check(
                "the missing sentence did not name anything",
                (call.missingSentence(in: catalogue.first { $0.id == "send_email" }) ?? "").hasPrefix("Needs ")
            )
        }

        // The measured failure, exactly: a grounded value in a field that cannot take it.
        // "Marcus" is in the sentence, so nothing flags it — and an email addressed to
        // "Marcus" fails after the user has already pressed Approve.
        let firstName = """
        {"calls":[{"tool":"send_email","arguments":[{"name":"to","value":"Marcus"},\
        {"name":"subject","value":"Updated pricing sheet"},{"name":"body","value":"The updated pricing sheet."}],\
        "quote":"Send Marcus the updated pricing sheet","confidence":95}]}
        """
        let nameCalls = (try? await LocalModelFunctionCallProposer { _, _, _ in firstName }
            .propose(fallbackRequest)) ?? []
        scriptedCalls += nameCalls.count
        check("a first name survived as an email address", nameCalls.first?.arguments["to"] == nil)
        check(
            "a first name in a recipient field was not reported missing",
            nameCalls.first?.missingArguments.contains("to") == true
        )

        // The quiet version of the same failure. Both backends are told "if a value was not
        // said, leave the argument out entirely" — so the *well-behaved* answer has no `to`
        // in it at all, and nothing was stripped. A call like that still has to come back
        // with the address reported missing, or the card shows no question and an enabled
        // Approve for a mail with no recipient.
        let omitted = """
        {"calls":[{"tool":"send_email","arguments":[{"name":"subject","value":"Updated pricing sheet"},\
        {"name":"body","value":"Here is the updated pricing sheet."}],\
        "quote":"Send Marcus the updated pricing sheet","confidence":90}]}
        """
        let omittedCalls = (try? await LocalModelFunctionCallProposer { _, _, _ in omitted }
            .propose(fallbackRequest)) ?? []
        scriptedCalls += omittedCalls.count
        check("an obedient answer with no address produced nothing at all", !omittedCalls.isEmpty)
        check(
            "AN ADDRESS NOBODY SAID WAS NEVER ASKED FOR: the call claimed to be complete",
            omittedCalls.first?.missingArguments.contains("to") == true
        )
        check(
            "a call with no recipient said it was ready to run",
            omittedCalls.first?.isComplete == false
        )

        // A call with nothing real left in it is not an incomplete proposal.
        let hollow = """
        {"calls":[{"tool":"send_email","arguments":[{"name":"to","value":"someone@nowhere.example"},\
        {"name":"subject","value":"Quarterly budget approval"},{"name":"body","value":"Quarterly budget approval"}],\
        "quote":"nothing like this was said","confidence":95}]}
        """
        let hollowCalls = (try? await LocalModelFunctionCallProposer { _, _, _ in hollow }
            .propose(fallbackRequest)) ?? []
        check("a call with nothing grounded in it reached the user", hollowCalls.isEmpty)

        // A second scripted answer: nothing was asked for.
        let quiet = LocalModelFunctionCallProposer { _, _, _ in #"{"calls":[]}"# }
        let quietCalls = (try? await quiet.propose(fallbackRequest)) ?? []
        check("the fallback invented a call out of an empty answer", quietCalls.isEmpty)

        // A third: the model was not sure. Confidence is a filter before anything else.
        let unsure = """
        {"calls":[{"tool":"send_email","arguments":[{"name":"subject","value":"Pricing"}],\
        "quote":"maybe","confidence":20}]}
        """
        let unsureCalls = (try? await LocalModelFunctionCallProposer { _, _, _ in unsure }
            .propose(fallbackRequest)) ?? []
        check("a low-confidence guess reached the user", unsureCalls.isEmpty)

        // MARK: The failure of 2026-09-20, reconstructed
        //
        // Not a fixture about a model: the model's exact answer is written down here and put
        // through the real pipeline, so the regression is pinned whatever any engine does
        // next. `document_id` and `text` are both the user's own sentence, both perfectly
        // grounded in it, and the required-argument rule reads green — which is how this
        // reached an approval card with Approve already enabled.
        let browserCommand = "You open Google Chrome and go to youtube.com."
        let theFailure = """
        {"calls":[{"tool":"append_doc","arguments":[\
        {"name":"document_id","value":"You open Google Chrome"},\
        {"name":"text","value":"You open Google Chrome and go to youtube.com."}],\
        "quote":"You open Google Chrome and go to youtube.com.","confidence":88}]}
        """
        let failureRequest = FunctionCallRequest(utterance: browserCommand, tools: catalogue)
        let replayed = (try? await LocalModelFunctionCallProposer { _, _, _ in theFailure }
            .propose(failureRequest)) ?? []
        check(
            "THE 2026-09-20 APPEND_DOC PROPOSAL WOULD BE RAISED AGAIN: "
                + replayed.map(\.toolID).joined(separator: ", "),
            replayed.isEmpty
        )
        // And the same answer for the siblings, so the fix is a rule rather than a patch for
        // one sentence.
        for utterance in [
            "Open my Next Notes folder",
            "Play some music, something quiet",
            "What's on my calendar this afternoon?",
        ] {
            let echoed = theFailure.replacingOccurrences(
                of: "You open Google Chrome and go to youtube.com.", with: utterance
            )
            let calls = (try? await LocalModelFunctionCallProposer { _, _, _ in echoed }
                .propose(FunctionCallRequest(utterance: utterance, tools: catalogue))) ?? []
            check(
                "a proposal was raised for \u{201c}\(utterance)\u{201d}: "
                    + calls.map(\.toolID).joined(separator: ", "),
                calls.isEmpty
            )
        }

        // The abstention tool, answered. A model that says "none of these" has answered the
        // question, and nothing else in its reply is a second opinion worth showing.
        let abstained = """
        {"calls":[{"tool":"\(FunctionCallRelevance.abstentionToolID)","arguments":[],\
        "quote":"open chrome","confidence":95}]}
        """
        let abstainedCalls = (try? await LocalModelFunctionCallProposer { _, _, _ in abstained }
            .propose(fallbackRequest)) ?? []
        check("an abstention was turned into a call", abstainedCalls.isEmpty)
        check(
            "the abstention tool is missing from the grammar the sampler enforces",
            LocalModelFunctionCallProposer
                .grammar(for: FunctionCallRelevance.wireTools(for: catalogue))
                .matches(abstained)
        )

        // A command with a real request inside it is still a request. The relevance gate has
        // to refuse the nearest neighbour without refusing the sentence.
        let mixed = "Open Chrome, and email sarah@acme.com the Q3 deck."
        let mixedAnswer = """
        {"calls":[{"tool":"send_email","arguments":[{"name":"to","value":"sarah@acme.com"},\
        {"name":"subject","value":"Q3 deck"},{"name":"body","value":"Here is the Q3 deck."}],\
        "quote":"email sarah@acme.com the Q3 deck","confidence":90}]}
        """
        let mixedCalls = (try? await LocalModelFunctionCallProposer { _, _, _ in mixedAnswer }
            .propose(FunctionCallRequest(utterance: mixed, tools: catalogue))) ?? []
        check(
            "a real request was thrown away because the sentence also opened an app",
            mixedCalls.first?.arguments["to"] == "sarah@acme.com"
        )
        scriptedCalls += mixedCalls.count

        // A diary entry with no *when* anywhere in the words. The card cannot ask for a time
        // nobody said, so a proposal built from one is the app deciding a meeting exists.
        let timelessEvent = """
        {"calls":[{"tool":"create_event","arguments":[{"name":"title","value":"Deck review"},\
        {"name":"start","value":"2026-09-21T15:00:00-04:00"},\
        {"name":"end","value":"2026-09-21T16:00:00-04:00"}],\
        "quote":"we should get a meeting in about the deck","confidence":88}]}
        """
        let timeless = (try? await LocalModelFunctionCallProposer { _, _, _ in timelessEvent }
            .propose(FunctionCallRequest(
                utterance: "We should get a meeting in about the deck review at some point.",
                tools: catalogue
            ))) ?? []
        check(
            "a calendar entry was invented from a sentence with no time in it: "
                + (timeless.first?.arguments["start"] ?? "-"),
            timeless.isEmpty
        )
        let datedEvent = timelessEvent.replacingOccurrences(
            of: "we should get a meeting in about the deck",
            with: "let's get the deck review in the diary for Thursday morning"
        )
        let dated = (try? await LocalModelFunctionCallProposer { _, _, _ in datedEvent }
            .propose(FunctionCallRequest(
                utterance: "Let's get the deck review in the diary for Thursday morning.",
                tools: catalogue
            ))) ?? []
        check(
            "a calendar entry with a day said out loud was thrown away",
            dated.first?.toolID == "create_event"
        )
        scriptedCalls += dated.count

        // MARK: Needle, if it is here
        if let directory = SelfTest.value(after: "--selftest-function-calls") {
            NeedleModels.overrideDirectory = URL(fileURLWithPath: directory, isDirectory: true)
        }
        let needle = NeedleFunctionCallProposer()
        if let reason = await needle.unavailableReason {
            SelfTest.diagnostic("FUNCTION_CALLS_NEEDLE_ABSENT: \(reason)")
        } else {
            let (needleCalls, needleFailures) = await runFixtures(
                needle, tools: catalogue, holdToAccuracy: true
            )
            modelCalls += needleCalls
            failures.append(contentsOf: needleFailures)
        }

        // MARK: The fallback, against whatever model is really on this Mac
        //
        // Not a duplicate of the scripted runs above. Those drive the pipeline from a string
        // this file wrote; this one drives a model, and it is the only thing that can make
        // the verdict mean something on a machine with no Needle engine.
        //
        // Held to the safety rules but not to Needle's accuracy, and the difference is
        // deliberate. A general 4B model missing a request, or offering something for a
        // sentence that was not one, is the known cost of the fallback — the file that
        // implements it says so — and failing the run for it would mean a red probe about
        // model quality on every Mac without the download. Inventing an address is not in
        // that category: it is the failure the whole feature exists to prevent, and it fails
        // the run whichever model did it.
        let liveFallback = LocalModelFunctionCallProposer()
        if let reason = await liveFallback.unavailableReason {
            SelfTest.diagnostic("FUNCTION_CALLS_FALLBACK_ABSENT: \(reason)")
        } else {
            let (localCalls, localFailures) = await runFixtures(
                liveFallback, tools: catalogue, holdToAccuracy: false
            )
            modelCalls += localCalls
            failures.append(contentsOf: localFailures)
        }

        // MARK: The watcher's own plumbing
        failures.append(contentsOf: watcherFailures())
        failures.append(contentsOf: await drainFailures())

        // MARK: Verdict
        //
        // Every check above is a rule about a call. A run in which no model produced one
        // would satisfy all of them and mean nothing at all — so the scripted fixtures,
        // however many of them passed, cannot answer this.
        SelfTest.diagnostic(
            "FUNCTION_CALLS_COUNTS: model=\(modelCalls) scripted=\(scriptedCalls)"
        )
        check(
            "NO MODEL PRODUCED A SINGLE CALL \u{2014} neither the fast engine nor the model "
                + "on this Mac ran, so every rule above passed without any inference "
                + "happening",
            modelCalls > 0
        )

        for failure in failures {
            SelfTest.diagnostic("FUNCTION_CALLS_WRONG: \(failure)")
        }
        if failures.isEmpty {
            SelfTest.diagnostic("FUNCTION_CALLS_OK")
            return true
        }
        SelfTest.diagnostic("FUNCTION_CALLS_FAILED")
        return false
    }

    // MARK: - A real backend

    /// Runs every fixture through a backend that actually loads a model, and reports latency
    /// per proposal.
    ///
    /// Both real backends come through here. They answer the same question and are held to
    /// the same rules — the fallback is slower and worse, not permitted to invent things —
    /// and one runner means a rule cannot be enforced against Needle and quietly not against
    /// the model most people will actually be using.
    /// - Parameter holdToAccuracy: whether *noticing the right thing* is a failure or a
    ///   diagnostic. The safety rules — nothing invented, nothing ungrounded, nothing outside
    ///   the schema — are failures either way.
    private static func runFixtures(
        _ proposer: any FunctionCallProposer,
        tools: [FunctionCallTool],
        holdToAccuracy: Bool
    ) async -> (calls: Int, failures: [String]) {
        var failures: [String] = []
        var produced = 0
        let engine = proposer.backend.rawValue
        let byID = Dictionary(uniqueKeysWithValues: tools.map { ($0.id, $0) })

        /// A miss: a failure for the engine this feature is built on, a printed note for the
        /// one that is only there so the feature works at all.
        func noteAccuracy(_ message: String) {
            if holdToAccuracy {
                failures.append(message)
            } else {
                SelfTest.diagnostic("FUNCTION_CALLS_ACCURACY: \(message)")
            }
        }

        for fixture in fixtures {
            let request = FunctionCallRequest(
                utterance: fixture.utterance,
                window: fixture.window,
                tools: tools,
                facts: ["Today is \(Date().formatted(date: .complete, time: .omitted))."]
            )
            let started = Date()
            let calls: [ProposedFunctionCall]
            do {
                calls = try await proposer.propose(request)
            } catch {
                failures.append("\(engine) threw on \u{201c}\(fixture.name)\u{201d}: \(error.localizedDescription)")
                continue
            }
            let elapsed = Date().timeIntervalSince(started)
            produced += calls.count

            SelfTest.diagnostic(
                "FUNCTION_CALLS_LATENCY: \(engine) \(fixture.name) \(Int(elapsed * 1_000))ms "
                    + "\(calls.count) call(s)"
                    + (calls.isEmpty ? "" : " \u{2192} " + calls.map(\.toolID).joined(separator: ", "))
            )

            guard let expectedTool = fixture.expectedTool else {
                if !calls.isEmpty {
                    noteAccuracy(
                        "\(engine) offered \(calls.map(\.toolID).joined(separator: ", ")) "
                            + "for ordinary conversation (\u{201c}\(fixture.name)\u{201d})"
                    )
                }
                continue
            }

            guard let call = calls.first(where: { $0.toolID == expectedTool }) else {
                noteAccuracy(
                    "\(engine) did not propose \(expectedTool) for \u{201c}\(fixture.name)\u{201d}"
                        + (calls.isEmpty ? " (nothing at all)" : " (got \(calls.map(\.toolID).joined(separator: ", ")))")
                )
                // "Nothing at all" has four different causes — a low score, a name nobody
                // offered, every argument stripped, or a turn that did not finish — and the
                // proposal alone cannot tell them apart. Ask the engine again and print what
                // it actually said, so the failure is diagnosable from the terminal.
                if proposer.backend == .needle,
                   let raw = try? await NeedleRunner.shared.run(
                       input: NeedleFunctionCallProposer.input(for: request),
                       tools: tools,
                       facts: request.facts
                   ) {
                    SelfTest.diagnostic(
                        "FUNCTION_CALLS_RAW: \(fixture.name) confidence=\(raw.confidence ?? -1) "
                            + "calls=\(raw.functionCalls.map { "\($0.name)\($0.arguments)" }) "
                            + "ungrounded=\(raw.validation?.ungrounded ?? [])"
                    )
                }
                continue
            }

            for (name, expected) in fixture.expectedArguments {
                let actual = call.arguments[name]
                if actual?.lowercased() != expected.lowercased() {
                    noteAccuracy(
                        "\(engine)/\(fixture.name): \(name) was "
                            + "\(actual.map { "\u{201c}\($0)\u{201d}" } ?? "absent"), "
                            + "expected \u{201c}\(expected)\u{201d}"
                    )
                }
            }
            for name in fixture.expectedMissing {
                if let invention = call.arguments[name] {
                    failures.append(
                        "\(engine.uppercased()) INVENTED \(expectedTool).\(name) = "
                            + "\u{201c}\(invention)\u{201d} for \u{201c}\(fixture.name)\u{201d}"
                    )
                } else if !call.missingArguments.contains(name) {
                    failures.append(
                        "\(engine)/\(fixture.name): \(name) was neither present nor reported missing"
                    )
                }
            }

            // Whatever survived has to be defensible against what was said, every time —
            // not only in the fixtures that name an argument.
            let source = FunctionCallGrounding.normalize(request.groundingText)
            for (name, value) in call.arguments
            where !FunctionCallGrounding.isGrounded(value, in: source) {
                failures.append(
                    "\(engine)/\(fixture.name): \(name) = \u{201c}\(value)\u{201d} "
                        + "survived the grounding filter"
                )
            }
            if let descriptor = byID[expectedTool] {
                let unknown = Set(call.arguments.keys).subtracting(descriptor.parameters.map(\.name))
                if !unknown.isEmpty {
                    failures.append(
                        "\(engine)/\(fixture.name): arguments not in the schema: \(unknown.sorted())"
                    )
                }
            }
        }
        return (produced, failures)
    }

    // MARK: - The drain

    /// A sentence spoken while a proposal is still running must not be lost.
    ///
    /// This is the one part of the watcher that cannot be asserted as a pure function: it is
    /// about timing between the debounce and an in-flight task. So it runs the real thing
    /// with a scripted proposer that takes longer than the debounce, and asks the only
    /// question that separates the fixed code from the broken one — is the held trigger
    /// still sitting in `pending` when everything has gone quiet?
    ///
    /// Before the fix it was: `fire()` returned early on the busy branch, nothing re-armed
    /// the debounce, and the trigger stayed there until the next utterance overwrote it.
    private static func drainFailures() async -> [String] {
        var failures: [String] = []
        let store = FunctionCallStore.shared
        let watcher = FunctionCallWatcher(store: store)
        let realSetting = store.noticesMeetingsOverrideForTesting
        defer {
            store.noticesMeetingsOverrideForTesting = realSetting
            watcher.resetForTesting()
        }
        store.noticesMeetingsOverrideForTesting = true
        watcher.resetForTesting()

        /// Slower than the debounce on purpose — that gap is the bug's whole habitat.
        let slow = LocalModelFunctionCallProposer { _, _, _ in
            try? await Task.sleep(for: .milliseconds(900))
            return #"{"calls":[]}"#
        }
        watcher.proposerOverrideForTesting = slow

        let meetingID = UUID()
        func say(_ text: String, at time: TimeInterval) {
            watcher.ingest(TranscriptEvent(
                meetingID: meetingID, source: .mic, text: text,
                start: time, end: time + 3, isFinal: true
            ))
        }

        let debounce = Duration.milliseconds(FunctionCallWatcher.debounceMilliseconds + 150)
        say("Please send Sarah the quarterly deck this afternoon", at: 10)
        try? await Task.sleep(for: debounce)
        if watcher.pendingTriggerForTesting != nil {
            failures.append("the first sentence never left the debounce")
        }

        // Said while the first proposal is still running. This is the one that used to go
        // missing with no log line and no status change.
        say("And put the review in the diary for Thursday morning", at: 14)
        try? await Task.sleep(for: debounce)

        // Long enough for the first proposal to finish, the drain to re-arm, and the second
        // debounce to fire.
        try? await Task.sleep(for: .milliseconds(2_200))
        if let held = watcher.pendingTriggerForTesting {
            failures.append(
                "A SENTENCE SPOKEN DURING A PROPOSAL WAS NEVER RETRIED: "
                    + "\u{201c}\(held.utterance)\u{201d} is still waiting"
            )
        }
        return failures
    }

    // MARK: - Watcher

    /// The parts of the watcher that decide *whether* to ask, driven without audio.
    private static func watcherFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let watcher = FunctionCallWatcher(store: FunctionCallStore.shared)
        watcher.resetForTesting()

        let meetingID = UUID()
        // The arming rule, as a pure function, so the verdict does not depend on how this
        // machine's Settings happen to be set. A live `ingest` reads the user's own
        // "let the agent work during a meeting" switch, and a probe that quietly passed
        // because that switch was off would be testing nothing.
        func event(
            meetingID: UUID?,
            source: AudioSource,
            text: String,
            isFinal: Bool
        ) -> TranscriptEvent {
            TranscriptEvent(
                meetingID: meetingID, source: source, text: text,
                start: 10, end: 13, isFinal: isFinal
            )
        }
        func mayArm(_ event: TranscriptEvent, liveAgentEnabled: Bool = true) -> Bool {
            FunctionCallWatcher.mayArmProposal(
                event, isEnabled: true, liveAgentEnabled: liveAgentEnabled
            )
        }
        let spoken = event(
            meetingID: meetingID, source: .mic,
            text: "Send the deck to sarah@acme.com", isFinal: true
        )
        check("a meeting sentence did not arm a proposal", mayArm(spoken))
        check(
            "a dictation was treated as a request to the app",
            !mayArm(event(
                meetingID: nil, source: .mic,
                text: "Send the deck to sarah@acme.com", isFinal: true
            ))
        )
        check(
            "the other side of the call armed a proposal",
            !mayArm(event(
                meetingID: meetingID, source: .system,
                text: "Could you send me the deck please", isFinal: true
            ))
        )
        check(
            "a provisional armed a proposal",
            !mayArm(event(
                meetingID: meetingID, source: .mic,
                text: "Send the deck to sarah@acme.com", isFinal: false
            ))
        )
        check(
            "a one-word answer armed a proposal",
            !mayArm(event(meetingID: meetingID, source: .mic, text: "Yes.", isFinal: true))
        )
        check(
            "the user's own meeting-agent switch was ignored",
            !mayArm(spoken, liveAgentEnabled: false)
        )

        // And the live path itself. This used to be skipped whenever the user's meeting
        // switch was off — which is its default, so it was skipped everywhere, and the one
        // path the feature exists for had never been run end to end by anybody. The gate is
        // now read through the store, so it can be driven here without writing to the real
        // settings of the app the user has running.
        let store = FunctionCallStore.shared
        let realSetting = store.noticesMeetingsOverrideForTesting
        defer { store.noticesMeetingsOverrideForTesting = realSetting }

        store.noticesMeetingsOverrideForTesting = true
        watcher.ingest(spoken)
        check(
            "a meeting sentence did not reach the debounce",
            watcher.pendingTriggerForTesting?.meetingID == meetingID
        )
        watcher.resetForTesting()

        // And the other way: with the meeting switch off, the same sentence must not arm
        // anything — and the status must not claim to be ready for it either.
        store.noticesMeetingsOverrideForTesting = false
        watcher.ingest(spoken)
        check(
            "a meeting sentence armed a proposal with the meeting switch off",
            watcher.pendingTriggerForTesting == nil
        )
        check(
            "the status said \u{201c}Ready\u{201d} while the meeting path was inert",
            !FunctionCallStore.Status.ready(.needle, noticesMeetings: false).sentence
                .hasSuffix("asks first.")
        )
        check(
            "the status did not name the switch that turns meeting noticing on",
            FunctionCallStore.Status.ready(.localModel, noticesMeetings: false).sentence
                .contains(FunctionCallStore.Status.meetingToggleTitle)
        )
        check(
            "the status nagged about a switch that is already on",
            !FunctionCallStore.Status.ready(.needle, noticesMeetings: true).sentence
                .contains(FunctionCallStore.Status.meetingToggleTitle)
        )
        store.noticesMeetingsOverrideForTesting = realSetting
        watcher.resetForTesting()

        // The fallback must never be pointed at a cloud endpoint. It runs on a rolling
        // transcript window on every utterance; honouring an OpenRouter preference here
        // would be continuous upload of a meeting under a row that says "on this Mac".
        check(
            "a cloud model would have been used for background listening",
            LocalModelFunctionCallProposer.onDevicePreference(.openRouter) != .openRouter
        )
        for onDevice in [LLMProviderID.gemma4E4B, .appleFoundation, .localServer] {
            check(
                "an on-device choice (\(onDevice.rawValue)) was overridden",
                LocalModelFunctionCallProposer.onDevicePreference(onDevice) == onDevice
            )
        }

        // Two identical calls are one card.
        let call = ProposedFunctionCall(
            toolID: "send_email",
            arguments: ["to": "sarah@acme.com", "subject": "Deck"],
            confidence: 0.9,
            span: TranscriptSpan(text: "send the deck"),
            backend: .needle
        )
        var twin = call
        twin.arguments = ["subject": "deck", "to": "Sarah@Acme.com "]
        check(
            "two identical calls would have raised two cards",
            FunctionCallWatcher.identity(of: call) == FunctionCallWatcher.identity(of: twin)
        )
        var different = call
        different.arguments["to"] = "someone.else@acme.com"
        check(
            "two different calls collapsed into one",
            FunctionCallWatcher.identity(of: call) != FunctionCallWatcher.identity(of: different)
        )

        // The card's "why" line says who, and never borrows the user's voice for somebody
        // else's sentence.
        let meetingTrigger = FunctionCallWatcher.Trigger(
            utterance: "can you send the deck",
            span: TranscriptSpan(text: "can you send the deck", start: 42, end: 45),
            meetingID: meetingID,
            speaker: "Sarah",
            isDirectToAgent: false
        )
        // Every proposal this file raises is overheard — that is now the only kind it raises
        // — so every card says the app volunteered, and none of them borrows "You said this"
        // for a sentence the user did not address to it. The speaker is still carried, so
        // the copy can name whoever was talking.
        let attributed = FunctionCallWatcher.trigger(for: call, from: meetingTrigger)
        if case .overheard(let quote, let speaker, _) = attributed {
            check("the card lost who was talking", speaker == "Sarah")
            check("the card lost the words the proposal was built from", quote == "send the deck")
        } else {
            failures.append("a meeting proposal was not tagged as overheard: \(attributed)")
        }
        let direct = FunctionCallWatcher.trigger(
            for: call,
            from: FunctionCallWatcher.Trigger(
                utterance: "email sarah the deck",
                span: TranscriptSpan(text: "email sarah the deck"),
                meetingID: nil,
                speaker: nil,
                isDirectToAgent: true
            )
        )
        if case .overheard = direct {} else {
            failures.append("a proposal outside a meeting was not tagged as overheard")
        }
        check(
            "an overheard proposal claimed somebody had asked for it",
            !attributed.isAttributed && !direct.isAttributed
        )
        check("the card would quote nothing", attributed.quote != nil)

        // What actually crosses to the approval card. This is the hand-off the whole
        // feature exists to make, and it is the one place an invented value would become
        // an approved value.
        if let tool = AgentToolRegistry.shared.tool(named: "send_email") {
            let incomplete = ProposedFunctionCall(
                toolID: "send_email",
                arguments: ["subject": "Updated pricing sheet", "body": "The pricing sheet."],
                missingArguments: ["to"],
                confidence: 0.9,
                span: TranscriptSpan(text: "send Marcus the updated pricing sheet", start: 12, end: 15),
                backend: .needle
            )
            let request = FunctionCallWatcher.request(
                for: incomplete,
                tool: tool,
                trigger: meetingTrigger
            )
            check(
                "an argument nobody said was carried to the approval card",
                request.arguments["to"] == nil
            )
            check("the card lost the subject that was said", request.arguments["subject"] != nil)
            check(
                "the card did not say what it still needs",
                request.detail.lowercased().contains("needs")
            )
            check("the card lost the sentence it is about", request.trigger.quote != nil)
            check("the card lost the meeting it belongs to", request.meetingID != nil)
            check(
                "a send was not graded as something that speaks in the user's name",
                request.risk == .send
            )
            // The review builder is the tool-approval workstream's; this asserts the seam
            // rather than their rules — an absent required argument has to become a
            // question, or the missing address is simply never asked for.
            let review = ToolCallReviewStore.build(request)
            check(
                "an absent required argument did not become a question on the card",
                review.blockers.contains { $0.name == "to" }
            )
            check("a card with a question on it offered Approve", !review.isReadyToRun)
        } else {
            failures.append("send_email is not in the registry")
        }

        // MARK: Who owns the turn
        //
        // The second half of the 2026-09-20 failure. The user woke the agent and gave it an
        // instruction; `VoiceConversationCoordinator.handle` ran the turn *and* handed the
        // same sentence to this watcher, which raised a competing card eight seconds later
        // while the agent was still acting on the real request. One utterance, two agents.
        store.noticesMeetingsOverrideForTesting = true
        watcher.resetForTesting()
        watcher.agentBusyOverrideForTesting = true
        watcher.ingest(spoken)
        check(
            "A PROPOSAL WAS ARMED WHILE AN AGENT TURN WAS IN FLIGHT",
            watcher.pendingTriggerForTesting == nil
        )
        watcher.agentBusyOverrideForTesting = false
        watcher.resetForTesting()
        watcher.agentBusyOverrideForTesting = false
        watcher.ingest(spoken)
        check(
            "the watcher stayed silent when no agent turn was running",
            watcher.pendingTriggerForTesting != nil
        )

        // A sentence addressed to the assistant never proposes, whatever else is true. The
        // call site is the handler for a turn the agent is about to answer; a second opinion
        // from a 35 MB classifier is a competitor, not a safety net.
        watcher.resetForTesting()
        watcher.agentBusyOverrideForTesting = false
        watcher.noteUserTurn("open Google Chrome and go to youtube.com")
        check(
            "A SENTENCE SPOKEN TO THE AGENT ARMED A PROPOSAL OF ITS OWN",
            watcher.pendingTriggerForTesting == nil
        )
        // And it silences ambient listening for a moment afterwards: the agent's tool loop
        // runs for several seconds past its reply.
        watcher.ingest(spoken)
        check(
            "ambient listening resumed the instant the agent's turn was handed over",
            watcher.pendingTriggerForTesting == nil
        )
        watcher.resetForTesting()
        watcher.agentBusyOverrideForTesting = nil
        store.noticesMeetingsOverrideForTesting = realSetting

        // MARK: Approval safety
        //
        // "Approved as proposed" is written by `PermissionGate.respond`, whose only runtime
        // callers are the island's Approve button and the Agent sidebar's — so a person
        // pressed it. What made that press possible was a card with no blockers: every
        // required argument of `append_doc` held a value, because `document_id` was declared
        // free text and the value was a literal substring of what was said. These assert the
        // three separate reasons that cannot happen again.
        if let tool = AgentToolRegistry.shared.tool(named: "append_doc") {
            let overheard = FunctionCallWatcher.Trigger(
                utterance: "You open Google Chrome and go to youtube.com.",
                span: TranscriptSpan(text: "You open Google Chrome and go to youtube.com."),
                meetingID: meetingID,
                speaker: AudioSource.mic.defaultSpeaker,
                isDirectToAgent: false
            )
            // What a model would have to produce for this to be reached at all.
            let append = ProposedFunctionCall(
                toolID: "append_doc",
                arguments: ["text": "the rollout date slipped to the 14th"],
                missingArguments: ["document_id"],
                confidence: 0.9,
                span: TranscriptSpan(text: "put that in the planning doc", start: 20, end: 24),
                backend: .needle
            )
            let request = FunctionCallWatcher.request(
                for: append, tool: tool, trigger: overheard
            )
            let review = ToolCallReviewStore.build(request)
            check(
                "A WRITE TO A GOOGLE DOC WITH NO DOCUMENT OFFERED APPROVE",
                !review.isReadyToRun
            )
            check(
                "the card did not ask which document",
                review.blockers.contains { $0.name == "document_id" }
            )
            check(
                "a Google Doc write was not graded as something that creates",
                request.risk >= .write
            )
            // Origin. The card has to say the app volunteered — the 2026-09-20 card said
            // "You said …" and quoted an instruction the user had given to the assistant,
            // which is true and is the most misleading true sentence available.
            if case .overheard = request.trigger {} else {
                failures.append(
                    "A WATCHER PROPOSAL WAS NOT TAGGED AS OVERHEARD: \(request.trigger)"
                )
            }
            check(
                "an overheard proposal claimed somebody had asked for it",
                !request.trigger.isAttributed
            )
            check(
                "the card did not say where the proposal came from",
                request.trigger.sentence.lowercased().contains("i heard this")
                    || request.trigger.sentence.lowercased().contains("i noticed this")
            )
        } else {
            failures.append("append_doc is not in the registry")
        }

        // No standing answer and no "without asking" switch may ever run a watcher proposal.
        // The watcher calls `PermissionGate.ask` directly rather than going through
        // `PermissionBroker`, so a grant is never even consulted — and the policy itself
        // refuses every consequential class under every authority, which is the belt under
        // that brace.
        for descriptor in FunctionCallCatalogue.current() {
            guard let tool = AgentToolRegistry.shared.tool(named: descriptor.id) else { continue }
            guard tool.risk >= .write else { continue }
            let authorities: [ActionAuthority] = [
                .user, .otherParticipant, .systemDerived, .background, .memoryReview,
                .scheduled(UUID()),
            ]
            for authority in authorities {
                check(
                    "A WATCHER-ELIGIBLE WRITE (\(descriptor.id)) AUTO-APPROVES UNDER "
                        + "\(authority.rawValue)",
                    !PermissionPolicy.selfTest.allowsAutomatically(tool, authority: authority)
                )
            }
            check(
                "a watcher-eligible write auto-approves with no authority at all",
                !PermissionPolicy.selfTest.allowsAutomatically(tool)
            )
            check(
                "a watcher-eligible write may run without a person",
                !tool.risk.mayAutoRun
            )
        }

        // And no watcher card can *create* a standing answer either. `AgentView` offers
        // "Always allow this action" only for a scoped request (`scope.kind != .any`) — a
        // browser call pinned to a domain, a file call pinned to a path. Everything this
        // file raises is unscoped, so the only button on it is Approve-once, and the next
        // identical proposal asks again. A write to a Google Doc must never become a
        // standing yes, and this is why it cannot.
        if let tool = AgentToolRegistry.shared.tool(named: "append_doc") {
            let unscoped = FunctionCallWatcher.request(
                for: ProposedFunctionCall(
                    toolID: "append_doc",
                    arguments: ["text": "the rollout slipped"],
                    missingArguments: ["document_id"],
                    confidence: 0.9,
                    span: TranscriptSpan(text: "put that in the planning doc"),
                    backend: .needle
                ),
                tool: tool,
                trigger: FunctionCallWatcher.Trigger(
                    utterance: "put that in the planning doc",
                    span: TranscriptSpan(text: "put that in the planning doc"),
                    meetingID: meetingID,
                    speaker: AudioSource.mic.defaultSpeaker,
                    isDirectToAgent: false
                )
            )
            check(
                "A WATCHER PROPOSAL CARRIED A SCOPE, WHICH WOULD OFFER "
                    + "\u{201c}ALWAYS ALLOW THIS ACTION\u{201d} FOR A GOOGLE DOC WRITE",
                unscoped.scope.kind == .any
            )
            check(
                "a watcher proposal claimed to belong to an agent task",
                unscoped.taskID == nil
            )
        }

        // MARK: Not stacking cards
        check(
            "more than one card of ours could be waiting at a time",
            FunctionCallWatcher.maximumOutstandingCards == 1
        )
        check(
            "a long meeting could drip out cards indefinitely",
            FunctionCallWatcher.maximumCardsPerWindow <= 5
                && FunctionCallWatcher.rateLimitWindow >= 300
        )
        check(
            "the cooldown after an agent turn is too short to cover its tool loop",
            FunctionCallWatcher.agentTurnCooldown >= 10
        )

        check(
            "the debounce left the window one burst of segments needs",
            FunctionCallWatcher.debounceMilliseconds >= 500
                && FunctionCallWatcher.debounceMilliseconds <= 1_500
        )
        check(
            "a stale card would outlive the sentence it is about by too much",
            FunctionCallWatcher.cardLifetime <= 600
        )

        watcher.resetForTesting()
        return failures
    }
}
