import Foundation

/// Which engine turned speech into a proposed call.
///
/// The names are internal. Nothing the user reads says "backend": the Settings row and the
/// island card talk about what the app *does*, not about which file did it.
enum FunctionCallBackend: String, Sendable, Codable, CaseIterable, Equatable {
    /// Needle 3 by Cactus — a 35 MB tool-calling model run as a child process.
    case needle
    /// The local notes model (local model, or whatever `LLMProviders` resolves), decoding under a
    /// GBNF grammar. Slower and less accurate, but it needs no second download.
    case localModel

    /// What the Settings row says is doing the work. Plain language, no model names.
    var displayName: String {
        switch self {
        case .needle: "Fast listening"
        case .localModel: "Standard listening"
        }
    }
}

/// The exact words that triggered a proposal, and where they sit on the recording clock.
///
/// Kept with every proposal because an approval card that cannot quote the sentence is
/// asking the user to trust the model rather than their own memory — and because a meeting
/// proposal is answered the next morning, when "you said this" is the only evidence left.
struct TranscriptSpan: Sendable, Equatable, Codable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval

    init(text: String, start: TimeInterval = 0, end: TimeInterval = 0) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// One argument a backend produced, and whether it is allowed to be used.
///
/// The distinction is the whole point of this type. A small model asked for "send Marcus the
/// pricing sheet" will happily write `marcus.chen@proton.me`, and that address is not a
/// mistake the approval card can catch — it looks exactly like a real one. So an argument
/// whose value cannot be found in what was actually said (or in context the app can retrieve)
/// never reaches `arguments`; it is named in `missingArguments` instead, and the card asks.
struct ProposedFunctionCall: Sendable, Equatable, Identifiable {
    let id: String
    /// The catalogue id — `send_email`, `meeting.transcript`, `schedule.create`.
    let toolID: String
    /// Only the arguments that are grounded in the transcript span or the request's context.
    var arguments: [String: String]
    /// Required arguments nothing supplied. Never guessed, never filled in.
    var missingArguments: [String]
    /// The backend's own calibrated score, 0…1. Used to drop noise, never to skip approval.
    var confidence: Double
    var span: TranscriptSpan
    /// The backend's sentence about why. Shown under the title; never acted on.
    var reasoning: String
    var backend: FunctionCallBackend
    /// Wall-clock seconds from handing the utterance over to having this call.
    var latency: TimeInterval

    init(
        id: String = UUID().uuidString,
        toolID: String,
        arguments: [String: String],
        missingArguments: [String] = [],
        confidence: Double,
        span: TranscriptSpan,
        reasoning: String = "",
        backend: FunctionCallBackend,
        latency: TimeInterval = 0
    ) {
        self.id = id
        self.toolID = toolID
        self.arguments = arguments
        self.missingArguments = missingArguments
        self.confidence = confidence
        self.span = span
        self.reasoning = reasoning
        self.backend = backend
        self.latency = latency
    }

    /// Whether every required argument is present. A complete call can be approved as it
    /// stands; an incomplete one has to be finished by the person first.
    var isComplete: Bool { missingArguments.isEmpty }

    /// "Needs the email address" — the sentence the card adds when something is absent.
    ///
    /// Written from the parameter descriptions rather than the parameter names, because
    /// "to" and "start_time" are field names in a schema nobody outside this file has read.
    func missingSentence(in tool: FunctionCallTool?) -> String? {
        guard !missingArguments.isEmpty else { return nil }
        let phrases = missingArguments.map { name -> String in
            tool?.parameters.first { $0.name == name }?.shortPhrase ?? name
        }
        return "Needs \(FunctionCallCopy.list(phrases))."
    }
}

/// One tool, flattened to what a function-calling model needs to see.
///
/// Deliberately not `AgentTool`: that type carries closures, a risk class, an execution mode
/// and a namespace, none of which cross into a child process, and it is `@MainActor`-adjacent
/// through its registry. This is the value that goes on the wire.
struct FunctionCallTool: Sendable, Equatable, Codable {
    /// What a value has to *look* like, over and above coming from what was said.
    ///
    /// Grounding alone is not enough, and the case that proves it is small: asked to "send
    /// Marcus the updated pricing sheet", Needle answers `to: "Marcus"`. That is perfectly
    /// grounded — the word is right there — and it is not an email address, so the send
    /// would fail after the user had already approved it. A recipient field wants an
    /// address or nothing.
    enum Shape: String, Sendable, Equatable, Codable {
        case text
        case longText
        /// One or more email addresses.
        case email
        /// A point in time the Workspace API will accept.
        case dateTime
        /// An opaque handle the API dereferences — a Google Docs `documentId`, a Gmail
        /// `messageId`. Measured, and the reason this case exists: asked about "open Google
        /// Chrome and go to youtube.com", Needle answered `append_doc` with
        /// `document_id: "You open Google Chrome…"`. That value is grounded — it is the
        /// sentence — and it is not an identifier, and `docs +write --document` would have
        /// been handed it. Nobody says a 44-character id out loud, so the honest answer for
        /// this field is almost always "missing", and the card asks which document.
        case identifier
    }

    struct Parameter: Sendable, Equatable, Codable {
        var name: String
        var description: String
        var isRequired: Bool
        var shape: Shape = .text

        /// The parameter as a person would name it, for "Needs …" copy.
        var shortPhrase: String {
            let sentence = description
                .split(separator: ".")
                .first
                .map { String($0).trimmingCharacters(in: .whitespaces) } ?? name
            guard !sentence.isEmpty else { return name }
            return sentence.prefix(1).lowercased() + sentence.dropFirst()
        }
    }

    var id: String
    var description: String
    var parameters: [Parameter]

    var requiredParameters: [String] { parameters.filter(\.isRequired).map(\.name) }

    /// The JSON one entry of Needle's `--tools` array, and of the fallback's prompt.
    var json: [String: Any] {
        var properties: [String: Any] = [:]
        for parameter in parameters {
            properties[parameter.name] = [
                "type": "string",
                "description": parameter.description,
            ]
        }
        return [
            "name": id,
            "description": description,
            "parameters": [
                "type": "object",
                "properties": properties,
                "required": requiredParameters,
            ] as [String: Any],
        ]
    }
}

/// Everything a proposer is given for one decision.
struct FunctionCallRequest: Sendable {
    /// What was just said — the utterance, or the sentence that closed a transcript window.
    var utterance: String
    /// The rolling window around it. Context only: a value found here but not in `utterance`
    /// still counts as grounded, because "Sarah's address is sarah@acme.com … send her the
    /// deck" is two sentences.
    var window: String
    var span: TranscriptSpan
    var tools: [FunctionCallTool]
    /// Session facts the model may use — today's date, the user's own name. Plain sentences.
    var facts: [String]

    init(
        utterance: String,
        window: String = "",
        span: TranscriptSpan? = nil,
        tools: [FunctionCallTool],
        facts: [String] = []
    ) {
        self.utterance = utterance
        self.window = window
        self.span = span ?? TranscriptSpan(text: utterance)
        self.tools = tools
        self.facts = facts
    }

    /// Everything a value may be grounded in.
    var groundingText: String { window.isEmpty ? utterance : "\(window)\n\(utterance)" }
}

/// Turns what somebody said into zero or more calls a person can approve.
///
/// Zero is a normal answer and the common one: most sentences in a meeting are not requests.
/// A proposer that returns a call for every utterance is worse than none, because the card
/// under the notch is then noise and gets switched off.
protocol FunctionCallProposer: Sendable {
    var backend: FunctionCallBackend { get }

    /// Why this proposer cannot run right now, or nil. Checked before every batch, because
    /// the answer changes when a download finishes.
    var unavailableReason: String? { get async }

    /// Loads whatever the backend needs. Idempotent; safe to call on every proposal.
    func prepare() async throws

    func propose(_ request: FunctionCallRequest) async throws -> [ProposedFunctionCall]
}

enum FunctionCallError: LocalizedError, Equatable {
    case notReady(String)
    case engineFailed(String)
    case badOutput(String)
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .notReady(let why): why
        case .engineFailed(let why): "The listening model could not run: \(why)"
        case .badOutput(let why): "The listening model answered with something unusable: \(why)"
        case .timedOut(let seconds): "The listening model took longer than \(Int(seconds))s."
        }
    }
}

/// Small shared copy helpers, so two files cannot word the same idea two ways.
enum FunctionCallCopy {
    /// "the email address", "the email address and the time", "a, b and c".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }
}
