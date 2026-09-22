import Foundation

/// Whether the catalogue has anything to do with what was actually said — decided without
/// the model, because the model cannot decide it.
///
/// ## The failure this exists for
///
/// On 2026-09-20 the user said, out loud, to the assistant: *"open Google Chrome and go to
/// youtube.com."* The conversation agent did the right thing (`browser.navigate`). In
/// parallel the watcher asked Needle, and Needle answered `append_doc` with the user's own
/// sentence in `document_id` and the same sentence as the text to add. Nothing downstream
/// stopped it: `document_id` was declared free text, so the shape check passed; the value was
/// a literal substring of the utterance, so the grounding check passed; every required
/// argument was therefore present, so the "nothing survived" rule passed; the approval card
/// had no blockers, so Approve was live. One press and the user's command was written into a
/// Google Doc.
///
/// The model was not malfunctioning. It was asked "which of these eight tools does this
/// sentence want?" with no browser tool in the list and no way to answer *none*, and it did
/// what a nearest-neighbour classifier does. The catalogue is deliberately small — reads,
/// shell, files and computer control are all excluded — so the set of sentences with no
/// answer in it is most sentences, and a proposer with no abstention is wrong for all of them.
///
/// ## What this does about it
///
/// Four independent rules, each of which alone would have stopped the failure. Independent on
/// purpose: a single cleverer prompt is one regression away from the same card.
///
/// 1. **A command to the computer is never a document or an email.** "Open", "go to",
///    "click", "play", "search for" aimed at an app, a site, a folder or the music are the
///    verbs of the tools this catalogue does *not* contain, and a sentence made only of them
///    is refused before the model is spawned — which also gives the turn back its second.
/// 2. **An informational question is not a request to write anything.** "What's on my
///    calendar" contains the word *calendar* and asks for nothing to be created.
/// 3. **Every tool has to be asked for in words.** `append_doc` needs somebody to have
///    mentioned a document, `send_email` needs a recipient or the words *email*/*send*. A
///    tool whose own vocabulary appears nowhere in the sentence was not what the sentence was
///    about.
/// 4. **A floor under the score**, per risk class, so a hedge never becomes a write.
///
/// And one thing the model is given rather than denied: a parameterless `no_action` tool, so
/// "none of these" is a move it can make instead of the nearest neighbour. Abstention has to
/// be representable before it can be chosen.
enum FunctionCallRelevance {

    /// The tool that means *nothing was asked for*.
    ///
    /// Declared to the engine and never executed: it is not in `AgentToolRegistry`, so even
    /// if everything below failed, `FunctionCallWatcher.present` would find no tool and stop.
    /// It is here so the model has somewhere to put a sentence that is not a request — the
    /// missing option is the whole reason a browser command came back as `append_doc`.
    static let abstentionToolID = "no_action"

    static var abstention: FunctionCallTool {
        FunctionCallTool(
            id: abstentionToolID,
            // Concrete, not a general nudge towards silence. "Prefer this when unsure" was
            // here and came out again: the four rules that actually enforce abstention are
            // code, and a broad thumb on the scale only costs the weaker backend the
            // proposals it does get right.
            description: "Nothing was asked for, or the request is not one of the other "
                + "tools. Use this for ordinary conversation, for questions, and for "
                + "anything about opening apps, browsing, clicking, searching or playing "
                + "media.",
            parameters: []
        )
    }

    /// The tool list that goes on the wire: the catalogue, plus somewhere to say no.
    static func wireTools(for tools: [FunctionCallTool]) -> [FunctionCallTool] {
        guard !tools.contains(where: { $0.id == abstentionToolID }) else { return tools }
        return tools + [abstention]
    }

    // MARK: - Before the model runs

    /// Why this utterance must not be put to a model at all, or nil.
    ///
    /// Cheap and first: a device command is the single most common thing said to this app,
    /// it can never map to anything in the catalogue, and spawning Needle for it costs a
    /// second of a machine that is also transcribing.
    static func preflightRefusal(_ request: FunctionCallRequest) -> String? {
        let utterance = request.utterance
        let ids = request.tools.map(\.id).filter { $0 != abstentionToolID }
        let declared = ids.isEmpty ? FunctionCallCatalogue.spokenOrder : ids
        if let target = deviceCommandTarget(utterance), !asksToWrite(utterance) {
            return "a command to the computer (\u{201c}\(target)\u{201d})"
        }
        if isInformationalQuestion(utterance), !asksToWrite(utterance) {
            return "a question, not a request"
        }
        if !namesAnyTool(in: utterance, or: request.window, toolIDs: declared) {
            return "nothing in the catalogue was named"
        }
        return nil
    }

    // MARK: - After the model answers

    /// Why this call must not reach a person, or nil to let it through.
    ///
    /// Runs after `FunctionCallGrounding.filter`, so `call.arguments` already holds only
    /// values somebody said and `call.missingArguments` names the rest.
    static func refusal(
        for call: ProposedFunctionCall,
        tool: FunctionCallTool,
        request: FunctionCallRequest
    ) -> String? {
        if call.toolID == abstentionToolID { return "the model abstained" }
        if let reason = preflightRefusal(request) { return reason }
        guard call.confidence >= minimumConfidence(for: tool.id) else {
            return "confidence \(String(format: "%.2f", call.confidence)) is under the floor "
                + "for \(tool.id)"
        }
        guard hasIntent(for: tool.id, in: request.utterance, or: request.window) else {
            return "\u{201c}\(tool.id)\u{201d} was never asked for in words"
        }
        if let slot = slotRefusal(for: call, tool: tool, source: request.groundingText) {
            return slot
        }
        return nil
    }

    /// Required-slot grounding, over and above "is this value in the words".
    ///
    /// The generic version of the rule is in `FunctionCallGrounding`; this is the part that
    /// needs to know what a particular tool is for. An append with no document is not an
    /// incomplete proposal the card can finish — nobody says a 44-character Google Docs id
    /// out loud, so the card would ask a question that has no spoken answer — but it is still
    /// worth showing, because the user can pick the document. An append whose *text* is the
    /// sentence that asked for it is not worth showing at all.
    static func slotRefusal(
        for call: ProposedFunctionCall,
        tool: FunctionCallTool,
        source: String = ""
    ) -> String? {
        // A call in which nothing the tool needs survived is a hallucination with a form
        // attached. Both backends already apply this; repeated here so the rule holds for
        // any backend added later.
        let required = tool.requiredParameters
        if !required.isEmpty, required.allSatisfy({ call.arguments[$0] == nil }) {
            return "every required argument of \(tool.id) was invented"
        }
        switch tool.id {
        case "append_doc", "workspace.append_doc":
            guard call.arguments["text"] != nil else {
                return "append_doc had no text that was actually said"
            }
        case "create_doc", "workspace.create_doc":
            guard call.arguments["markdown"] != nil || call.arguments["title"] != nil else {
                return "create_doc had neither a title nor a body"
            }
        case "send_email", "workspace.send_email", "draft_email", "workspace.draft_email":
            guard call.arguments["body"] != nil || call.arguments["subject"] != nil else {
                return "\(tool.id) had nothing to say"
            }
        case "create_event", "workspace.create_event":
            // A diary entry needs a *when*, and the card cannot usefully ask for one that
            // was never said: an event proposed from a sentence with no time in it is the
            // app deciding a meeting should exist. `containsTimeExpression` is deliberately
            // broad — "Thursday morning", "at 3", "next week" all count.
            guard source.isEmpty
                || FunctionCallGrounding.containsTimeExpression(
                    FunctionCallGrounding.normalize(source)
                ) else {
                return "create_event was proposed from a sentence with no time in it"
            }
        default:
            break
        }
        return nil
    }

    // MARK: - The score floor

    /// Tools that create or send something another person can see.
    private static let consequentialIDs: Set<String> = [
        "send_email", "draft_email", "reply_email", "create_doc", "append_doc",
        "upload_to_drive", "create_event",
        "workspace.send_email", "workspace.draft_email", "workspace.reply_email",
        "workspace.create_doc", "workspace.append_doc", "workspace.upload_to_drive",
        "workspace.create_event",
    ]

    /// The floor under a score, by what the tool would do.
    ///
    /// Calibrated rather than chosen, and deliberately low. Measured on this Mac: a real
    /// request scores 0.41–1.00 against this catalogue and ordinary conversation scores 0.19,
    /// and the same sentence scores differently again when the number of declared tools
    /// changes — so a gate placed by taste silently empties the feature. The floor here sits
    /// below every measured true positive and above the measured noise, and the rules around
    /// it are what actually filter. Anything not in the catalogue's own families is held
    /// higher, because an unknown tool arrived from MCP or Composio and nothing here knows
    /// what it does.
    static func minimumConfidence(for toolID: String) -> Double {
        if consequentialIDs.contains(toolID) { return 0.35 }
        if toolID.hasPrefix("memory.") || toolID.hasPrefix("schedule.") { return 0.35 }
        return 0.5
    }

    // MARK: - Device commands

    /// The thing a device command was aimed at, or nil.
    ///
    /// Two halves, and both are needed: the verb alone is ambiguous ("open the doc and add a
    /// line" is an append), and the noun alone is ambiguous ("email the Chrome team"). A verb
    /// bound to an app, a site, a window, the file system or the music is a request for a
    /// tool this catalogue does not contain.
    static func deviceCommandTarget(_ utterance: String) -> String? {
        let text = FunctionCallGrounding.normalize(utterance)
        guard deviceVerbs.contains(where: { text.contains(" \($0) ") }) else { return nil }
        for target in deviceTargets where text.contains(" \(target) ") {
            return target
        }
        // "go to youtube.com", "open nextnotes.app" — a bare host is a browser target even
        // when the name is one nothing here has heard of.
        if text.range(of: #"\b[a-z0-9-]+\.(com|org|net|io|ai|app|dev|co|tv|me)\b"#,
                      options: [.regularExpression]) != nil {
            return "a website"
        }
        return nil
    }

    /// A device command, and nothing in it asks for anything to be created or sent.
    ///
    /// The escape hatch is a *verb*, not a noun, and that distinction is measured rather than
    /// stylistic: "Open my Next Notes folder" contains the word *notes*, which is legitimate
    /// vocabulary for `create_doc`, and letting an incidental noun cancel the refusal put the
    /// folder command straight back in front of the model. "Open Chrome, and email Sarah the
    /// deck" still escapes, because *email* is somebody asking for something to happen.
    static func isDeviceCommand(_ utterance: String) -> Bool {
        deviceCommandTarget(utterance) != nil && !asksToWrite(utterance)
    }

    /// Verbs that drive a machine rather than ask for something to be created or sent.
    private static let deviceVerbs: Set<String> = [
        "open", "launch", "start", "run", "go", "navigate", "browse", "visit", "click",
        "tap", "press", "scroll", "switch", "quit", "close", "minimise", "minimize",
        "maximise", "maximize", "play", "pause", "resume", "skip", "mute", "unmute",
        "screenshot", "reveal", "show", "bring", "search", "google", "type", "paste",
        "copy", "download", "install", "restart", "shut",
    ]

    /// Things only a computer-control or browser tool can act on.
    private static let deviceTargets: Set<String> = [
        "chrome", "safari", "firefox", "edge", "arc", "browser", "tab", "window",
        "youtube", "youtube.com", "google.com", "spotify", "music", "song", "playlist",
        "video", "volume", "finder", "folder", "desktop", "dock", "terminal", "app",
        "application", "website", "site", "page", "url", "link", "screen", "settings",
        "preferences", "notes", "slack", "zoom", "teams",
        // Things only a click lands on.
        "button", "menu", "icon", "field", "checkbox", "toolbar", "sidebar", "result",
        "results", "player",
    ]

    // MARK: - Questions

    /// Whether the sentence asks for information rather than for something to happen.
    ///
    /// A leading wh-word only. "Can you email sarah@acme.com the deck?" is a question in
    /// grammar and an instruction in fact, and treating every question mark as a refusal
    /// would throw away the politest half of the true positives.
    static func isInformationalQuestion(_ utterance: String) -> Bool {
        let text = FunctionCallGrounding.normalize(utterance)
        for opener in questionOpeners where text.hasPrefix(" \(opener) ") || text.hasPrefix(" \(opener)s ") {
            return true
        }
        return false
    }

    private static let questionOpeners: [String] = [
        "what", "whats", "when", "where", "who", "whose", "why", "which", "how",
        "is", "are", "was", "were", "do", "does", "did", "have", "has", "am",
    ]

    /// Whether an otherwise interrogative sentence still asks for something to be made or
    /// sent — "what's the address, and can you send her the deck".
    static func asksToWrite(_ utterance: String) -> Bool {
        let text = FunctionCallGrounding.normalize(utterance)
        return writeVerbs.contains { text.contains(" \($0) ") }
    }

    private static let writeVerbs: Set<String> = [
        "send", "email", "mail", "draft", "reply", "forward", "write", "append",
        "schedule", "book", "invite", "remind", "remember", "create", "add",
    ]

    // MARK: - Per-tool vocabulary

    /// The words that have to appear before a tool may be proposed at all.
    ///
    /// Written as what a person says, not as what the schema is called. A user does not say
    /// "append_doc"; they say "add that to the doc". A tool whose vocabulary is absent was
    /// not the subject of the sentence, whatever the model's nearest neighbour was.
    static func cues(for toolID: String) -> [String] {
        switch toolID {
        case "send_email", "workspace.send_email":
            return ["email", "e mail", "mail", "send", "forward", "shoot"]
        case "draft_email", "workspace.draft_email":
            return ["email", "e mail", "mail", "draft", "send", "write to"]
        case "reply_email", "workspace.reply_email":
            return ["reply", "replies", "respond", "answer", "get back to"]
        case "create_doc", "workspace.create_doc":
            return ["doc", "docs", "document", "write up", "write-up", "notes", "minutes"]
        case "append_doc", "workspace.append_doc":
            return ["doc", "docs", "document", "append", "add to", "put in", "write it in"]
        case "upload_to_drive", "workspace.upload_to_drive":
            return ["drive", "upload"]
        case "create_event", "workspace.create_event":
            // No "put the" and no "set up". Both were here and both came out: "put the deck
            // in the shared folder" is not a calendar entry, and a cue that broad means the
            // vocabulary rule stops filtering anything for this tool.
            return [
                "calendar", "diary", "schedule", "meeting", "invite", "book", "appointment",
                "sync", "catch up", "stand up", "standup",
            ]
        case "memory.remember":
            return ["remember", "forget", "note that", "keep in mind", "make a note", "memory"]
        default:
            if toolID.hasPrefix("schedule.") {
                return ["remind", "reminder", "every day", "every week", "every morning",
                        "routine", "trigger", "schedule", "recurring", "each time"]
            }
            // An MCP or Composio tool nothing here has heard of: its own name is the only
            // vocabulary available, so it has to be said.
            return toolID
                .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
                .map(String.init)
                .filter { $0.count >= 4 }
        }
    }

    /// `normalize` pads both ends with a space, so `" cue "` is a word-boundary match at the
    /// start and the end of the sentence as well as in the middle.
    static func hasIntent(for toolID: String, in utterance: String, or window: String = "") -> Bool {
        let cues = cues(for: toolID)
        guard !cues.isEmpty else { return false }
        let said = FunctionCallGrounding.normalize(utterance)
        if cues.contains(where: { said.contains(" \($0) ") }) { return true }
        guard !window.isEmpty else { return false }
        // A continuation — "alright, send her the deck then" after two lines about the deck —
        // may borrow its vocabulary from the window, but only the last few lines of it.
        let recent = FunctionCallGrounding.normalize(
            window.split(separator: "\n").suffix(4).joined(separator: " ")
        )
        return cues.contains { recent.contains(" \($0) ") }
    }

    /// Whether any tool the app is prepared to offer was named. Used before the model runs,
    /// when the particular tool is not yet known.
    ///
    /// `toolIDs` defaults to the families this app ships, so the rule can be checked from a
    /// self-test without a registry; the live path passes the catalogue it is actually
    /// declaring, which is what an MCP server's tool would come in on.
    static func namesAnyTool(
        in utterance: String,
        or window: String = "",
        toolIDs: [String] = FunctionCallCatalogue.spokenOrder
    ) -> Bool {
        toolIDs.contains { hasIntent(for: $0, in: utterance, or: window) }
    }
}
