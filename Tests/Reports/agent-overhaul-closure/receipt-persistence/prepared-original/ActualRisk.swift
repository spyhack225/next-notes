import Foundation
enum AgentRisk: String, Codable, Sendable, CaseIterable, Comparable {
    /// Looks at what is already on screen or in a meeting. Automatic.
    case observe
    /// Looks something up. Runs without asking when `Settings.agentAutoRunReadTools` is on.
    case read
    /// Changes a local file or UI the user already owns. Confirmation depends on scope.
    case modify
    /// Creates or changes something the user owns. One click.
    case write
    /// Says something as the user. One click, and the full message is shown first.
    ///
    /// This is the "communicate" class in the v2 roadmap. The raw value stays `send` so a
    /// proposal written before the rename still decodes as the same thing.
    case send
    /// Spends the user's money. One click, and the card shows the exact amount, the
    /// payment method and the cap it was checked against.
    ///
    /// Ranked between `send` and `destructive`: money out is harder to take back than a
    /// sent message and easier to replace than deleted data. Never auto-runs.
    ///
    /// Documented choice (roadmap AGENT-COMPETITOR-GAP P1/D5): a distinct risk class
    /// rather than a `requiresCapCheck` flag on the tool, so `max` over a plan, the
    /// permission broker and the approval card all see it without special-casing one
    /// tool id. The cap itself stays per-call (`capCents`), checked in
    /// `BrowserToolExecutor.purchase`, not in the class.
    case purchase
    /// Deletes or irreversibly destroys something. Strong confirmation.
    case destructive
    /// Installs software, runs as root, or otherwise leaves the user's machine. Strong
    /// confirmation, and never an "always allow everything" escape.
    case privileged

    var displayName: String {
        switch self {
        case .observe: "Observes"
        case .read: "Reads"
        case .modify: "Edits"
        case .write: "Creates"
        case .send: "Sends"
        case .purchase: "Purchases"
        case .destructive: "Deletes"
        case .privileged: "Privileged"
        }
    }

    /// Whether running this changes something outside the app.
    ///
    /// Not the same question as `mayAutoRun`, and deliberately named apart from it: that one
    /// is a permission policy, this one is a fact about the world, and a policy change must not
    /// silently move which replies count as claims of an action. The two agree today, and
    /// `ToolClaimGuard` wants the fact — a reply that says it *sent* something is claiming an
    /// effect, and a `filesystem.search` does not have one.
    var changesSomething: Bool {
        switch self {
        case .observe, .read: false
        case .modify, .write, .send, .purchase, .destructive, .privileged: true
        }
    }

    /// Whether this class may ever run without a person pressing a button.
    var mayAutoRun: Bool {
        switch self {
        case .observe, .read: true
        case .modify, .write, .send, .purchase, .destructive, .privileged: false
        }
    }

    /// Whether executing this leaves something another person can see.
    var speaksForTheUser: Bool { self == .send }

    /// Ordered by consequence, so `max` over a set of tools answers "what is the worst this
    /// could do".
    private var rank: Int {
        switch self {
        case .observe: 0
        case .read: 1
        case .modify: 2
        case .write: 3
        case .send: 4
        case .purchase: 5
        case .destructive: 6
        case .privileged: 7
        }
    }

    static func < (lhs: AgentRisk, rhs: AgentRisk) -> Bool { lhs.rank < rhs.rank }

    /// A proposal written by a newer build may name a class this build has never heard
    /// of. A decoding surprise must never auto-run and must never take the file with
    /// it, so an unknown raw value reads as `.send`: the most cautious class that still
    /// renders a card a person can approve or refuse.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentRisk(rawValue: raw) ?? .send
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Which pass offered a proposal.
///
/// The distinction is what stops one unanswered mid-meeting card from standing in for the
/// review that runs when the meeting ends: "has this meeting been reviewed" is a question
/// about a pass, not about whether anything happens to be on the list.
