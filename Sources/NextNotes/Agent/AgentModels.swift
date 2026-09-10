import Foundation

/// How much a tool can cost if the model is wrong about wanting it.
///
/// The three classes are the whole permission model, and they are graded by what can't be
/// taken back: reading is invisible to everyone else, writing leaves something the user can
/// delete, and sending puts words in the user's name in front of another person. Nothing
/// about the model's confidence changes which class a tool is in — the class is a property
/// of the tool.
enum AgentRisk: String, Codable, Sendable, CaseIterable, Comparable {
    /// Looks something up. Runs without asking when `Settings.agentAutoRunReadTools` is on.
    case read
    /// Creates or changes something the user owns. One click.
    case write
    /// Says something as the user. One click, and the full message is shown first.
    case send

    var displayName: String {
        switch self {
        case .read: "Reads"
        case .write: "Creates"
        case .send: "Sends"
        }
    }

    /// Ordered by consequence, so `max` over a set of tools answers "what is the worst this
    /// could do".
    private var rank: Int {
        switch self {
        case .read: 0
        case .write: 1
        case .send: 2
        }
    }

    static func < (lhs: AgentRisk, rhs: AgentRisk) -> Bool { lhs.rank < rhs.rank }
}

/// Which pass offered a proposal.
///
/// The distinction is what stops one unanswered mid-meeting card from standing in for the
/// review that runs when the meeting ends: "has this meeting been reviewed" is a question
/// about a pass, not about whether anything happens to be on the list.
enum AgentProposalSource: String, Codable, Sendable {
    /// The pass that runs once, after the meeting has finished.
    case review
    /// One of the passes that run every couple of minutes while it is still going.
    case live
}

/// One thing the agent has offered to do, waiting for a person to say yes.
///
/// Codable because a proposal outlives the process that made it: the app can be quit
/// between "notes are ready" and the user getting round to reading them, and a proposal
/// that evaporates on relaunch is a feature that only works if you were watching.
struct AgentProposal: Identifiable, Sendable, Equatable, Codable {
    let id: String
    let meetingID: UUID
    /// The tool's name, as it appears in the catalogue. Kept as a string rather than an enum
    /// so a proposal written by an older build decodes instead of taking the file with it.
    let tool: String
    /// Flat and stringly-typed on purpose: these are the values shown in the Actions tab and
    /// edited there before approval, and every one of them ends up as a command-line
    /// argument. A list-valued argument is comma-separated, which is also what `gws` takes.
    var arguments: [String: String]
    /// The model's own sentence about why. Shown under the title; never acted on.
    let rationale: String
    var createdAt: Date = Date()
    /// Which pass offered it. Optional because a proposal written by an older build has no
    /// such field, and one that failed to decode would take the whole file with it — nil
    /// reads as `.review`, which is what every proposal from before this existed was.
    let source: AgentProposalSource?

    /// Whether this came from the post-meeting pass, an undecided old file included.
    var isFromReview: Bool { (source ?? .review) == .review }

    /// The catalogue entry, when this build still has one. A proposal naming a tool that has
    /// since been removed is shown and refused rather than silently run as something else.
    var definition: WorkspaceTool? { WorkspaceTools.tool(named: tool) }

    /// Unknown tools are treated as the most dangerous class, so a decoding surprise can
    /// never auto-run.
    var risk: AgentRisk { definition?.risk ?? .send }

    /// "Email the action items to Ana" — the one line on the card.
    var title: String { definition?.title(for: arguments) ?? tool }

    /// The full text of anything being sent, shown before approval. Nil for tools that don't
    /// put words in the user's name.
    var messagePreview: String? { definition?.preview(for: arguments) }

    init(
        id: String = UUID().uuidString,
        meetingID: UUID,
        tool: String,
        arguments: [String: String],
        rationale: String,
        createdAt: Date = Date(),
        source: AgentProposalSource? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.tool = tool
        self.arguments = arguments
        self.rationale = rationale
        self.createdAt = createdAt
        self.source = source
    }
}

/// What a tool produced, once it ran.
struct WorkspaceToolResult: Sendable {
    /// What the model — or the log — should be told. Trimmed to something readable.
    let summary: String
    /// The identifier Google gave back: a document id, an event id, a message id.
    let reference: String?
    /// Where the user can go and look at it.
    let link: URL?

    init(summary: String, reference: String? = nil, link: URL? = nil) {
        self.summary = summary
        self.reference = reference
        self.link = link
    }
}

/// A tool that actually ran, recorded on the meeting.
///
/// Written into `meeting.json` rather than kept in memory because the answer to "did I
/// already email these notes to the room?" has to survive a quit — and because the link is
/// the only way back to the document afterwards.
struct AgentActionRecord: Identifiable, Sendable, Equatable, Codable {
    /// The proposal's id, so an action can't be recorded twice for one approval.
    var id: String
    var tool: String
    /// The proposal's title, frozen at the moment it ran: the arguments are not kept, since
    /// they contain the body of whatever was sent.
    var title: String
    var performedAt: Date
    var reference: String?
    var link: URL?
    /// What the tool said, for the ones that answer rather than create — an approved
    /// `search_email` has no link to open, and a row that only said "Search email" would
    /// have thrown the answer away.
    var detail: String?
    /// Set when the run failed, so a failed attempt is visible rather than merely absent.
    var failure: String?
    /// Carried over from the proposal, so a meeting whose only agent action came from a
    /// mid-meeting pass still gets its post-meeting review. Nil in files written before this
    /// existed, and read as `.review` there.
    var source: AgentProposalSource?

    var succeeded: Bool { failure == nil }

    /// Whether this came out of the post-meeting pass, an old file included.
    var isFromReview: Bool { (source ?? .review) == .review }
}

enum AgentError: LocalizedError, Equatable {
    case disabled
    case notSignedIn
    case noProvider
    case emptyTranscript
    case contextTooSmall
    case unknownTool(String)
    case missingArgument(name: String, tool: String)
    case noProposals

    var errorDescription: String? {
        switch self {
        case .disabled:
            "The meeting agent is turned off."
        case .notSignedIn:
            "The Google Workspace CLI isn\u{2019}t signed in."
        case .noProvider:
            "No local model is available to plan follow-up actions."
        case .emptyTranscript:
            "There is nothing in this meeting to act on."
        case .contextTooSmall:
            "This model has too little room left to read the meeting once the tools are "
                + "described to it."
        case .unknownTool(let name):
            "This build has no tool called \u{201c}\(name)\u{201d}."
        case .missingArgument(let name, let tool):
            "\(tool) needs \u{201c}\(name)\u{201d}, and it is empty."
        case .noProposals:
            "Nothing in this meeting needed following up."
        }
    }
}
