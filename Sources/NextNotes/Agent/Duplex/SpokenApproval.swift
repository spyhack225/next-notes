import Foundation

/// A live proposal's deterministic spoken preview. Nothing here grants permission.
/// PermissionGate.ask remains unbounded: silence, delivery failure and session close
/// never approve a proposal. The actual Gate is the sole decision/continuation owner.
struct SpokenApprovalPrompt: Sendable, Equatable {
    let text: String
    let voiceMayApprove: Bool
    let refusal: String?
    let verb: String
    let readsFullMessage: Bool
    let messageBody: String?
    /// Exact executable values, including pinned hidden arguments; no hash collision.
    let executionArguments: [String: String]
}
struct SpokenApprovalState: Sendable, Equatable {
    let request: PermissionRequest
    let task: TaskID
    let workRevision: Int
    var callerGeneration: Int? = nil
    let originSession: UUID
    let prompt: SpokenApprovalPrompt
    var recipient: UUID?
    var output: OutputID?
    var outputGeneration: UInt64?
    var heardStart = false
    var heardFully = false
    var clarified = false
}
enum ApprovalOutcome: Sendable, Equatable {
    case approved, denied, noPendingRequest, notSessionOwned
    case refusedNotSpeakable(String), notReady(String)
}
enum SpokenApprovalReading: Sendable, Equatable {
    case approve, deny, hold, ambiguous, amend(String), unrelated
}

@MainActor
enum SpokenApproval {
    static let sendPreviewLimit = 400
    static let approveKeys: Set<String> = ["yes", "yeah", "yep", "yes please", "go ahead", "yes go ahead", "do it", "yes do it", "send it", "yes send it", "please do", "approve", "approved", "sure", "sure go ahead", "go for it", "that s fine", "sounds good", "yes that s right"]
    static let denyKeys: Set<String> = ["no", "nope", "no thanks", "no thank you", "don t", "don t send it", "do not send it", "don t do it", "no don t", "no stop", "don t bother"]
    static let holdKeys: Set<String> = ["wait", "hold on", "wait a second", "wait a minute", "not yet", "hang on", "one second", "give me a second", "let me think", "let me check"]
    static let ambiguousKeys: Set<String> = ["okay", "ok", "hmm", "maybe", "i guess", "i think so", "fine", "right", "alright", "all right", "mm"]
    static func read(_ utterance: String) -> SpokenApprovalReading {
        let key = VoiceTurnPolicy.normalizedKey(utterance)
        if approveKeys.contains(key) { return .approve }
        if denyKeys.contains(key) { return .deny }
        if holdKeys.contains(key) { return .hold }
        if ambiguousKeys.contains(key) { return .ambiguous }
        let prefixes = ["yes but ", "yeah but ", "yes and ", "no ", "actually ", "instead "]
        if prefixes.contains(where: { key.hasPrefix($0) && key.dropFirst($0.count).split(separator: " ").count >= 2 })
            || key.split(separator: " ").contains("instead") || key.split(separator: " ").contains("change") {
            return .amend(utterance)
        }
        return .unrelated
    }
    static func modelApprovalAllowed(_ utterance: String) -> Bool {
        if read(utterance) == .approve { return true }
        let key = " " + VoiceTurnPolicy.normalizedKey(utterance) + " "
        let negative = ["no", "not", "don t", "wait", "stop", "cancel", "instead", "but"]
        guard !negative.contains(where: { key.contains(" " + $0 + " ") }) else { return false }
        return ["yes", "yeah", "yep", "go ahead", "send it", "do it", "approve"].contains { key.contains(" " + $0 + " ") }
    }
    static func prompt(for request: PermissionRequest, review: ToolCallReview, updated: Bool = false) -> SpokenApprovalPrompt {
        let arguments = review.executionArguments(mergedOver: request.arguments)
        let recipients = review.fields.first(where: { $0.kind == .person && !$0.value.isEmpty })?.value
            ?? spokenRecipients(arguments["to"] ?? "")
        let what: String
        switch request.toolID {
        case "send_email", "workspace.send_email": what = "Send an email to " + recipients
        case "reply_email", "workspace.reply_email": what = "Send a reply in that email thread"
        case "draft_email", "workspace.draft_email": what = "Save a draft to " + recipients
        default:
            let title = review.title
            what = title.contains("@") || title.contains("://") || title.range(of: #"\d{6,}"#, options: .regularExpression) != nil
                ? "Make the change shown on screen" : title
        }
        let head = updated ? "Updated: " : ""
        var refusal: String?
        var mayApprove = [.observe, .read, .modify, .write, .send].contains(request.risk)
        var fullMessage = false
        var body: String?
        let verb: String
        let raw: String
        if !review.isReadyToRun {
            refusal = "Before I can do that: " + (review.blockers.first?.prompt ?? "please check the card")
            raw = head + what + ". " + refusal!
            verb = request.risk == .send ? "send it" : "go ahead"
            mayApprove = false
        } else if request.risk == .send {
            verb = "send it"
            let subject = arguments["subject"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let about = subject.isEmpty ? "" : ", about " + subject
            let preview = review.previewField.flatMap { arguments[$0] } ?? arguments["body"]
            if let preview, !preview.isEmpty, preview.count <= sendPreviewLimit {
                body = preview
                raw = head + what + about + ". It says: " + preview + " Should I send it?"
                fullMessage = true
            } else {
                refusal = "Please check the whole message and send it on screen."
                raw = head + what + about + ". The whole message is on screen for you to check."
                mayApprove = false
            }
        } else if request.risk >= .purchase {
            verb = "go ahead"; mayApprove = false
            refusal = "That one needs your OK on screen."
            raw = head + what + " needs your OK on screen."
        } else if request.risk <= .read {
            verb = "look"; raw = head + what + ". Should I look?"
        } else {
            verb = "go ahead"
            let details = review.fields.filter { $0.kind == .dateTime || $0.kind == .person }.prefix(2)
                .map { $0.value }.filter { !$0.isEmpty }.joined(separator: ", ")
            raw = head + what + (details.isEmpty ? "" : ", " + details) + ". Should I go ahead?"
        }
        var text = RealtimeAgent.voiceSafeReply(raw)
        // A scrubbed, clipped or unspeakable preview is not the whole executable
        // message. Use the actual audio policy before offering spoken approval.
        // Actual same-output ordered playback still has to finish the whole body.
        if let body, !text.contains(body) || !AgentSpeechPolicy.isSpeakableReply(text) {
            fullMessage = false; mayApprove = false
            refusal = "Please check the whole message and send it on screen."
            text = RealtimeAgent.voiceSafeReply(head + what + ". The whole message is on screen for you to check.")
        }
        return SpokenApprovalPrompt(text: text, voiceMayApprove: mayApprove, refusal: refusal,
            verb: verb, readsFullMessage: fullMessage, messageBody: body, executionArguments: arguments)
    }
    static func spokenRecipients(_ raw: String) -> String {
        let all = raw.split(whereSeparator: { $0 == "," || $0 == ";" }).map { String($0).trimmingCharacters(in: .whitespaces) }
        let first = all.prefix(3).map { $0.replacingOccurrences(of: "@", with: " at ").replacingOccurrences(of: ".", with: " dot ") }.joined(separator: ", ")
        return first + (all.count > 3 ? " and \(all.count - 3) more" : "")
    }
    static func clarifier(_ prompt: SpokenApprovalPrompt) -> String { "Just to be sure — should I " + prompt.verb + "? Yes or no." }
    static func holdReply() -> String { "Okay, it'll wait for you." }
    static func reply(for outcome: ApprovalOutcome, prompt: SpokenApprovalPrompt?) -> String {
        switch outcome {
        case .approved: prompt?.verb == "send it" ? "Sending it." : "Okay, doing it."
        case .denied: "Okay, I won't " + (prompt?.verb ?? "do that") + "."
        case .noPendingRequest: "Nothing is waiting for your OK right now."
        case .notSessionOwned: "That one is on screen for you to answer."
        case .refusedNotSpeakable(let text), .notReady(let text): text
        }
    }
}
