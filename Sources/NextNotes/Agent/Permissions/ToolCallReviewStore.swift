import Foundation
import Observation

/// The reviews currently on screen, and the only place the user's edits live.
///
/// One review per pending `PermissionRequest`, keyed by its id, so the island, the Agent
/// conversation and a meeting can all draw the same card and edit the same values. The
/// executor reads `approvedArguments(for:)` after the gate says yes — which is what makes
/// "edited values are what gets executed" true rather than a claim on a card.
@MainActor
@Observable
final class ToolCallReviewStore {
    static let shared = ToolCallReviewStore()

    private(set) var reviews: [String: ToolCallReview] = [:]
    /// Ids in the order they were built, so the oldest can be dropped.
    ///
    /// A review outlives its approval on purpose: whoever asked reads the user's edited
    /// arguments back *after* the gate returns, so `respond` cannot clear it. Nothing else
    /// then owns the last one of a session, and a long day of approvals would keep every
    /// message body it ever drew. The cap is what closes that, and it is generous enough
    /// that a queue of pending cards is never the thing evicted.
    @ObservationIgnored private var order: [String] = []
    /// For a meeting proposal, the arguments its stored review was built from. A proposal
    /// is re-read on every redraw and rewritten by its own editing sheet, so the store has
    /// to be able to tell "the same proposal again" from "this proposal has changed".
    @ObservationIgnored private var proposalSources: [String: [String: String]] = [:]
    private static let maximumRetained = 32

    private init() {}

    // MARK: - Building

    /// Builds the review for a request that is about to be shown, if it has not been built
    /// already. Returns what the card should draw.
    @discardableResult
    func begin(_ request: PermissionRequest) -> ToolCallReview {
        if let existing = reviews[request.id] { return existing }
        return store(Self.build(request), id: request.id)
    }

    @discardableResult
    private func store(_ review: ToolCallReview, id: String) -> ToolCallReview {
        reviews[id] = review
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > Self.maximumRetained, let oldest = order.first {
            order.removeFirst()
            reviews[oldest] = nil
            proposalSources[oldest] = nil
        }
        return review
    }

    /// The review for a request, without storing anything.
    ///
    /// Non-mutating on purpose: SwiftUI calls this from a view body, and writing to an
    /// `@Observable` store while a view is being evaluated is the "Modifying state during
    /// view update" warning and an invalidation loop behind it. `begin` is the only writer,
    /// and `PermissionGate.present` calls it before any card exists.
    func review(for request: PermissionRequest) -> ToolCallReview {
        reviews[request.id] ?? Self.build(request)
    }

    func review(id: String) -> ToolCallReview? { reviews[id] }

    static func build(_ request: PermissionRequest) -> ToolCallReview {
        let context = ToolCallContextBuilder.current(meetingID: request.meetingID)
        guard let tool = AgentToolRegistry.shared.tool(named: request.toolID) else {
            // An unknown tool is the most cautious case there is: show every argument as a
            // row, confirm nothing, and let the schema check refuse it downstream.
            return ToolCallReviewBuilder.review(
                id: request.id,
                tool: AgentTool.native(
                    namespace: .mcp, name: request.toolID, description: request.detail,
                    risk: request.risk, title: request.title),
                arguments: request.arguments,
                trigger: request.trigger,
                context: context
            )
        }
        return ToolCallReviewBuilder.review(
            id: request.id, tool: tool, arguments: request.arguments,
            trigger: request.trigger, context: context
        )
    }

    /// The stored review for a meeting proposal, built once and then kept.
    ///
    /// The meeting card used to build its review in a computed property read from a SwiftUI
    /// body, which was wrong twice over. It re-read the transcript and the notes off disk
    /// three or four times per redraw — 110 KB files, on the main actor. And because every
    /// read started from scratch, an address the user typed into the editing sheet came back
    /// through the inspector as the model's own invention: `.inferred`, then "not
    /// confirmed", then Approve disabled, then "Fill in 1 thing…" again. The loop had no
    /// exit for a correct address that was simply never spoken out loud, which is the normal
    /// case for a recording with no calendar attendees.
    ///
    /// Storing it puts a proposal on exactly the same footing as a pending request: edits
    /// are `.edited`, a value the user vouches for is confirmed, and both survive the next
    /// redraw. `arguments` is what the review was built from, so a proposal the agent has
    /// since rewritten is rebuilt and one the user has just edited is not.
    @discardableResult
    func beginProposal(
        id: String,
        toolID: String,
        arguments: [String: String],
        meetingID: UUID?,
        evidence: String?,
        risk: AgentRisk,
        title: String
    ) -> ToolCallReview {
        if let existing = reviews[id], proposalSources[id] == arguments { return existing }
        proposalSources[id] = arguments
        return store(
            Self.review(
                proposalID: id, toolID: toolID, arguments: arguments, meetingID: meetingID,
                evidence: evidence, risk: risk, title: title),
            id: id
        )
    }

    /// The user saved the proposal's editing sheet. Every value they left is theirs, which
    /// is the difference between a card that can be approved and one that argues with the
    /// sheet it was just filled in from: `update` marks each one `.edited`, so a real
    /// address nobody happened to say out loud stops being reported as unconfirmed.
    func applyEdits(id: String, arguments: [String: String]) {
        guard var review = reviews[id] else { return }
        for field in review.fields {
            review.update(field.name, to: arguments[field.name] ?? "")
        }
        reviews[id] = review
        proposalSources[id] = arguments
    }

    /// The review for a meeting proposal, without storing anything.
    static func review(
        proposalID: String,
        toolID: String,
        arguments: [String: String],
        meetingID: UUID?,
        evidence: String?,
        risk: AgentRisk,
        title: String
    ) -> ToolCallReview {
        let context = ToolCallContextBuilder.current(meetingID: meetingID)
        let trigger: ToolCallTrigger = (evidence?.isEmpty == false)
            ? .saidInMeeting(evidence!, speaker: nil, at: nil)
            : .unattributed
        guard let tool = AgentToolRegistry.shared.tool(named: toolID) else {
            return ToolCallReviewBuilder.review(
                id: proposalID,
                tool: AgentTool.native(namespace: .mcp, name: toolID, description: title,
                                       risk: risk, title: title),
                arguments: arguments, trigger: trigger, context: context)
        }
        return ToolCallReviewBuilder.review(
            id: proposalID, tool: tool, arguments: arguments, trigger: trigger, context: context)
    }

    // MARK: - Editing

    func update(id: String, field: String, to value: String) {
        guard var review = reviews[id] else { return }
        review.update(field, to: value)
        reviews[id] = review
    }

    func confirm(id: String, field: String) {
        guard var review = reviews[id] else { return }
        review.confirm(field)
        reviews[id] = review
    }

    // MARK: - Reading back

    /// What should actually run, once the user has approved. Nil when there is no review,
    /// in which case the caller keeps the arguments it already had.
    func approvedArguments(for id: String) -> [String: String]? {
        reviews[id]?.arguments
    }

    func isReadyToRun(id: String) -> Bool {
        reviews[id]?.isReadyToRun ?? true
    }

    func remove(id: String) {
        reviews[id] = nil
        proposalSources[id] = nil
        order.removeAll { $0 == id }
    }

    func removeAll() {
        reviews = [:]
        proposalSources = [:]
        order = []
    }
}

/// Gathers the haystack the inspector checks against, once, on the main actor.
///
/// Every source here is read-only and cheap. Nothing model-backed: a card that waited on a
/// 4B model to tell it whether an address was real would take a minute to appear, and the
/// question — "is this string in any of these strings" — does not need one.
@MainActor
enum ToolCallContextBuilder {

    static func current(meetingID: UUID? = nil, userWords: String? = nil) -> ToolCallContext {
        var context = ToolCallContext()
        context.now = Date()
        context.userWords = userWords ?? lastUserWords()

        if let meetingID {
            if let meeting = MeetingStore.shared.meeting(id: meetingID) {
                context.attendees = meeting.attendees
                context.people += meeting.speakerNames.values
            }
            context.transcript = MeetingStore.shared.transcript(for: meetingID)
                .map(\.text).joined(separator: "\n")
            context.notes = MeetingStore.shared.notes(for: meetingID) ?? ""
            if let live = MeetingContextStore.shared.current, live.meetingID == meetingID {
                context.transcript += "\n" + live.summary
                context.people += live.participants
            }
        } else if let live = MeetingContextStore.shared.current {
            // A conversation held while a meeting is running can legitimately lean on what
            // is being said in it.
            context.transcript = live.summary
            context.people += live.participants
        }

        context.people += knownPeople()
        context.knownEmails = (context.attendees + context.people)
            .flatMap { ToolCallInspector.emails(in: $0) }
        context.memory = memoryText()
        return context
    }

    /// The user's own most recent words, spoken or typed. Not the whole conversation: the
    /// question the card answers is "did *you* ask for this", and a name that appeared
    /// three days ago is context, which is a different label.
    private static func lastUserWords() -> String {
        let recent = AgentSession.shared.messages.suffix(6).filter { $0.role == "user" }
        return recent.map(\.text).joined(separator: "\n")
    }

    /// Everyone the app can name: resolved graph people and the speakers a meeting was
    /// told about. Both are the user's own data; neither is a lookup.
    private static func knownPeople() -> [String] {
        var names: [String] = []
        let resolution = PersonResolutionService.shared
        if resolution.isEnabled {
            names += resolution.people.map(\.name)
            names += resolution.people.flatMap { $0.members.map(\.label) }
        }
        return names.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func memoryText() -> String {
        NextMemory.shared.items.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }
}
