import Foundation

/// What the user is shown before a tool runs, and the only thing that decides whether it
/// may run at all.
///
/// The card this feeds used to say two sentences — "Request supplier? You said this." — and
/// the buttons were Dismiss and Approve. That is a permission model for an action whose
/// arguments are already right. The arguments are frequently not right: a 4B model asked to
/// send an email will happily write `to: [Name]`, `to: john.doe@example.com`, or an address
/// that appears nowhere in the meeting, and a card that shows none of that turns a
/// fabrication into an approved fabrication.
///
/// So a review is built from the tool's own schema rather than from prose: one field per
/// parameter, each carrying where its value came from, and an `isReadyToRun` that is false
/// while anything is missing, is a placeholder, or was invented. Nothing here guesses a
/// value — a field the model left out stays `.missing` and the card asks for it.
///
/// Pure value types on purpose: `--selftest-tool-review` walks every rule without a screen,
/// a model or an account.

// MARK: - Where a value came from

/// Provenance of one value on the card. The user never sees these words; they pick the
/// sentence under the field.
enum ToolCallProvenance: String, Codable, Sendable, CaseIterable {
    /// It is in what the user themselves said or typed.
    case userSaid
    /// It is in the transcript, the invite, the notes, memory or the people the app knows.
    case fromContext
    /// The model wrote it and nothing confirms it. Never presented as fact.
    case inferred
    /// Absent, or present and empty.
    case missing
    /// The user typed or confirmed it on this card. The strongest of the five.
    case edited

    /// Whether the card may present this value as something the user can trust at a glance.
    var isConfirmed: Bool {
        switch self {
        case .userSaid, .fromContext, .edited: true
        case .inferred, .missing: false
        }
    }
}

/// What a field holds, which decides the control drawn for it and how hard it is checked.
enum ToolCallFieldKind: String, Codable, Sendable {
    case text
    case longText
    case email
    case dateTime
    case person
    case file
    case choice

    /// Kinds that name something in the world. A subject line the model composed is its
    /// job; an email address it composed is a fabrication, and only these are checked
    /// against what was actually said.
    var isFactual: Bool {
        switch self {
        case .email, .dateTime, .person, .file, .choice: true
        case .text, .longText: false
        }
    }
}

/// Why a field is not ready. One of these is what the card highlights.
enum ToolCallFieldProblem: String, Codable, Sendable {
    /// Required and empty.
    case missing
    /// Filled with a stand-in: "[Name]", "TBD", john.doe@example.com, a 555 number.
    case placeholder
    /// A real-looking value that appears nowhere the app can check.
    case notConfirmed
}

// MARK: - One field

/// One argument, as a person reads it.
struct ToolCallField: Identifiable, Sendable, Equatable, Codable {
    /// The schema's own name. What reaches the executor.
    let name: String
    /// Plain language. "Who it goes to", never "to".
    let label: String
    var value: String
    let isRequired: Bool
    let kind: ToolCallFieldKind
    var provenance: ToolCallProvenance
    /// The short question the card asks when this field is not ready.
    let prompt: String
    /// Where the value came from, in one phrase: "Marie was in this meeting."
    var origin: String?
    /// The exact values inside this field that nothing confirms. For a message body this
    /// is the addresses and dates embedded in it, not the prose around them.
    var unverified: [String] = []
    /// What is wrong with it, if anything.
    var problem: ToolCallFieldProblem?
    /// For `.choice`.
    var options: [String] = []
    /// Answers the app can already point at — people on the invite, people the knowledge
    /// store has resolved. Offered, never applied: filling a blank recipient in with the
    /// only attendee is the app doing the inventing instead of the model.
    var suggestions: [String] = []

    var id: String { name }

    /// Whether this field is the reason Approve is off.
    var needsAnswer: Bool { problem != nil }

    /// The sentence under the field.
    var statusLine: String {
        switch problem {
        case .missing: prompt
        case .placeholder: "This is a stand-in, not a real answer. \(prompt)"
        case .notConfirmed:
            unverified.isEmpty
                ? "Not confirmed — nothing you said mentions this."
                : "Not confirmed — I did not find \(unverified.joined(separator: ", ")) anywhere."
        case nil:
            origin ?? (provenance == .edited ? "You entered this." : "")
        }
    }
}

// MARK: - Why the agent wants to do this

/// The one line explaining what triggered the call, with the words that triggered it.
enum ToolCallTrigger: Sendable, Equatable, Codable {
    /// The user's own words, spoken or typed.
    case youSaid(String)
    /// Somebody in a meeting. `at` is an offset into the recording.
    case saidInMeeting(String, speaker: String?, at: TimeInterval?)
    /// The background listener noticed it. Nobody addressed the app; it was listening while
    /// the user talked, and it is asking on its own initiative.
    ///
    /// Separate from `saidInMeeting` because the two cards are answered differently. "Marie
    /// said this at 07:42" reads as a record of a request; an overheard proposal is the app
    /// volunteering, and a card that does not say so borrows the authority of a request
    /// nobody made. The 2026-09-20 `append_doc` card said "You said …" and quoted the user's
    /// instruction to the assistant — true, and the most misleading true sentence available.
    case overheard(String, speaker: String?, at: TimeInterval?)
    /// The meeting notes, which are written rather than said.
    case fromNotes(String)
    /// A reminder or routine the user set up earlier.
    case routine(String)
    /// The first read from a newly connected account (§8.2's two-step ingestion consent).
    /// The app is the one asking — nobody asked it — so the card says so instead of
    /// borrowing an attribution nobody made. The associated value is the account as the app
    /// can name it; there is deliberately no quote, because nobody said anything for one to
    /// quote. What the person is deciding on is the card's body: the findings themselves.
    case firstUse(String)
    /// Nothing quotable. Said plainly rather than dressed up.
    case unattributed

    /// The exact words, when there are any.
    var quote: String? {
        switch self {
        case .youSaid(let quote), .saidInMeeting(let quote, _, _), .fromNotes(let quote),
             .overheard(let quote, _, _):
            let trimmed = quote.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .routine, .firstUse, .unattributed:
            return nil
        }
    }

    /// One sentence for the card.
    var sentence: String {
        switch self {
        case .youSaid:
            guard let quote else { return "You asked for this." }
            return "You said \u{201c}\(Self.clip(quote))\u{201d}."
        case .saidInMeeting(_, let speaker, let at):
            guard let quote else { return "Someone asked for this in the meeting." }
            let who = speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (who?.isEmpty == false) ? who! : "Someone"
            if let at { return "\(name) said this at \(Self.clock(at)): \u{201c}\(Self.clip(quote))\u{201d}." }
            return "\(name) said this in the meeting: \u{201c}\(Self.clip(quote))\u{201d}."
        case .overheard(_, let speaker, let at):
            // Says three things in one sentence, because all three are load-bearing: nobody
            // asked, the app was listening, and here are the exact words so the user can
            // tell whether it understood them.
            guard let quote else {
                return "I noticed this while you were talking \u{2014} want me to?"
            }
            let who = speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
            let voice = (who?.isEmpty == false) && who != "You"
                ? "\(who!) said" : "you said"
            let when = at.map { " at \(Self.clock($0))" } ?? ""
            return "I heard this while \(voice)\(when) \u{2014} nobody asked me to: "
                + "\u{201c}\(Self.clip(quote))\u{201d}. Want me to?"
        case .fromNotes:
            guard let quote else { return "This came out of the meeting notes." }
            return "The meeting notes say \u{201c}\(Self.clip(quote))\u{201d}."
        case .routine(let name):
            return "\(name) asked for this on its own schedule."
        case .firstUse(let account):
            return "The first time I read from \(account), I ask before anything it finds is used."
        case .unattributed:
            return "Nobody asked for this in so many words — check it before it runs."
        }
    }

    /// Whether the card may say a person asked for this. An unattributed call is exactly
    /// the case the old copy ("You said this.") got wrong.
    var isAttributed: Bool {
        switch self {
        case .youSaid, .saidInMeeting, .fromNotes: quote != nil
        case .routine: true
        // Never. The whole point of this case is that the app is volunteering: a card that
        // claimed attribution for it would be claiming somebody asked.
        case .overheard, .firstUse, .unattributed: false
        }
    }

    private static func clip(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > 140 else { return flat }
        return flat.prefix(139).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - The review

/// Everything the approval card shows, and the gate the executor honours.
struct ToolCallReview: Identifiable, Sendable, Equatable, Codable {
    /// The same id as the `PermissionRequest` this belongs to.
    let id: String
    let toolID: String
    /// "Send an email to Marie". A sentence, not a function name.
    var title: String
    var trigger: ToolCallTrigger
    var fields: [ToolCallField]
    var risk: AgentRisk
    /// Which field holds the long body worth previewing, if any.
    var previewField: String?
    /// Set the moment the user changes anything. The audit log records it.
    private(set) var wasEdited = false
    /// Fields the user changed or confirmed, in the order they did it.
    private(set) var editedFields: [String] = []

    init(
        id: String,
        toolID: String,
        title: String,
        trigger: ToolCallTrigger,
        fields: [ToolCallField],
        risk: AgentRisk,
        previewField: String? = nil
    ) {
        self.id = id
        self.toolID = toolID
        self.title = title
        self.trigger = trigger
        self.fields = fields
        self.risk = risk
        self.previewField = previewField
    }

    // MARK: Reading

    var why: String { trigger.sentence }

    /// Fields the user has to answer before this can run.
    ///
    /// A value nothing confirms stops a write or a send, and does not stop a read: the
    /// harm is in acting on an invented address, not in looking one up, and a card that
    /// refused to search for a name the user had not said out loud would be unusable. The
    /// "not confirmed" label is still shown either way — it is the *blocking* that is
    /// reserved for the actions that cannot be taken back.
    var blockers: [ToolCallField] {
        fields.filter { field in
            guard field.needsAnswer else { return false }
            if field.problem == .notConfirmed, risk <= .read { return false }
            return true
        }
    }

    /// Approve is off while this is false. Never computed from the model's confidence.
    var isReadyToRun: Bool { blockers.isEmpty }

    /// The collapsed line: the card has to stay glanceable under the notch.
    /// "2 things needed" — never a number of fields the user cannot see.
    var needsSummary: String? {
        let count = blockers.count
        guard count > 0 else { return nil }
        return count == 1 ? "1 thing needed" : "\(count) things needed"
    }

    /// Values that are present and real-looking but that nothing confirms. Shown as
    /// "not confirmed", never as fact.
    var unconfirmed: [ToolCallField] { fields.filter { $0.problem == .notConfirmed } }

    func field(_ name: String) -> ToolCallField? { fields.first { $0.name == name } }

    /// What actually reaches the executor: the user's edits, not the model's draft.
    var arguments: [String: String] {
        var result: [String: String] = [:]
        for field in fields {
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            result[field.name] = value
        }
        return result
    }

    /// What should run, given what the model proposed.
    ///
    /// The card's own fields win, including a field the user emptied. What it does *not* do
    /// is throw the rest away: `ToolCallReviewBuilder` deliberately keeps underscore-prefixed
    /// arguments off the card — they are machinery rather than anything to approve — and on
    /// a browser call they are the authorization the executor pinned before the card went
    /// up (`_browserBackend`, `_authorizedPageURL`). Replacing the whole set with the card's
    /// fields dropped them, and a click the user approved against one tab then landed on
    /// whichever tab resolved afterwards.
    func executionArguments(mergedOver proposed: [String: String]) -> [String: String] {
        var merged = arguments
        for (name, value) in proposed where name.hasPrefix("_") && merged[name] == nil {
            merged[name] = value
        }
        return merged
    }

    // MARK: Writing

    /// The user typed a value. Placeholders are still refused — a person who types
    /// "[Name]" gets the same answer the model does — but nothing they typed is ever
    /// second-guessed as "not confirmed".
    mutating func update(_ name: String, to value: String) {
        guard let index = fields.firstIndex(where: { $0.name == name }) else { return }
        guard fields[index].value != value else { return }
        fields[index].value = value
        fields[index].provenance = .edited
        fields[index].unverified = []
        fields[index].origin = "You entered this."
        fields[index].problem = ToolCallInspector.problem(
            value: value,
            isRequired: fields[index].isRequired,
            kind: fields[index].kind,
            provenance: .edited,
            unverified: [],
            risk: risk,
            name: name
        )
        noteEdit(name)
    }

    /// "Yes, that address is right." The user vouching for a value the app could not
    /// confirm is a confirmation; it is not the app deciding it was fine after all.
    mutating func confirm(_ name: String) {
        guard let index = fields.firstIndex(where: { $0.name == name }) else { return }
        guard fields[index].problem == .notConfirmed else { return }
        fields[index].provenance = .edited
        fields[index].unverified = []
        fields[index].origin = "You confirmed this."
        fields[index].problem = nil
        noteEdit(name)
    }

    private mutating func noteEdit(_ name: String) {
        wasEdited = true
        editedFields.removeAll { $0 == name }
        editedFields.append(name)
    }

    /// One line for the audit log, so a record of what ran says whose values ran.
    var auditNote: String {
        guard wasEdited else { return "Approved as proposed" }
        return "Approved after you edited \(editedFields.joined(separator: ", "))"
    }
}

extension ToolCallField {
    /// The value, short enough for a one-line summary.
    var shortValue: String {
        let flat = value.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > 40 else { return flat }
        return flat.prefix(39) + "\u{2026}"
    }
}
