import Foundation

/// One fact waiting for a tick in the review step.
struct ProposedMemory: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: MemoryEntry.Kind
    /// Editable in place; `original` is what the distiller produced.
    var text: String
    let original: String
    var isSelected: Bool
    /// The fact already remembered that says the same thing, when there is one. A duplicate
    /// arrives unticked rather than hidden: "you already know this" is worth seeing.
    var duplicateOf: String?

    init(kind: MemoryEntry.Kind, text: String, duplicateOf: String? = nil) {
        id = UUID()
        self.kind = kind
        self.text = text
        original = text
        self.duplicateOf = duplicateOf
        isSelected = duplicateOf == nil
    }

    var isEdited: Bool { text != original }
}

/// A fact that will not be imported, and why, in words the person can act on.
struct DroppedMemory: Identifiable, Equatable, Sendable {
    let id = UUID()
    let text: String
    let reason: String
}

/// What one import is proposing, before anything is saved.
struct MemoryImportPlan: Sendable {
    /// What the saved facts will say they came from: "Grok", "ChatGPT", a file's name.
    var origin: String
    var proposals: [ProposedMemory] = []
    var dropped: [DroppedMemory] = []
    /// The model that read the notes, or nil when the wording was worked out without one.
    var modelLabel: String?
    /// Something worth saying above the list — that this was a conversation download, say.
    var note: String?

    var selected: [ProposedMemory] { proposals.filter(\.isSelected) }
    var duplicateCount: Int { proposals.filter { $0.duplicateOf != nil }.count }
    var isEmpty: Bool { proposals.isEmpty }

    /// Characters the ticked facts of one kind would add.
    func selectedCharacters(_ kind: MemoryEntry.Kind) -> Int {
        selected.filter { $0.kind == kind }.reduce(0) { $0 + $1.text.count }
    }
}

/// Screens distilled facts and works out which ones are already known.
///
/// **Imported text is untrusted.** Every fact goes through `NextMemory.validated` here — the
/// same invisible-character, injection, exfiltration and permission scan a memory written by
/// the Agent gets, plus the declarative rule — and anything it refuses is listed as dropped
/// rather than quietly discarded. The store runs the identical check again at write time;
/// this pass exists so the person can see what was thrown out and why, not to replace it.
///
/// What is deliberately *not* applied is `MemoryGuard.provenanceProblem`. That guard asks
/// "did the user say this, or did the model read it somewhere?", and it is what stops an
/// email writing itself into memory. An import has a different answer: the person went and
/// fetched this, looked at every line, and ticked the ones they wanted. Provenance here is
/// the review step, and each saved fact carries the name of where it came from.
enum MemoryImportPlanner {
    /// How alike two facts have to be to count as the same one. Token overlap, so "The user
    /// prefers short answers" and "The user prefers short replies" are near enough.
    static let duplicateOverlap = 0.7

    static func plan(
        facts: [String], existing: [MemoryEntry], origin: String,
        modelLabel: String? = nil, note: String? = nil
    ) -> MemoryImportPlan {
        var plan = MemoryImportPlan(origin: origin, modelLabel: modelLabel, note: note)
        var kept: [(kind: MemoryEntry.Kind, tokens: Set<String>, text: String)] = []

        for fact in facts {
            let text: String
            do {
                text = try NextMemory.validated(fact)
            } catch {
                plan.dropped.append(DroppedMemory(text: MemoryImportPlanner.preview(fact),
                                                  reason: reason(for: error)))
                continue
            }
            let kind = MemoryFactRewriter.kind(of: text)
            let tokens = Set(MemoryGuard.contentTokens(text))

            // Two lines of the same import saying the same thing is noise, not a choice.
            if kept.contains(where: { isSameFact($0.tokens, tokens, $0.text, text) }) {
                continue
            }
            let twin = existing.first { isSameFact(Set(MemoryGuard.contentTokens($0.text)), tokens,
                                                   $0.text, text) }
            kept.append((kind, tokens, text))
            plan.proposals.append(ProposedMemory(kind: kind, text: text, duplicateOf: twin?.text))
        }
        return plan
    }

    /// Word for word after normalising, or enough shared content words to be the same fact.
    static func isSameFact(_ lhs: Set<String>, _ rhs: Set<String>, _ left: String, _ right: String) -> Bool {
        if NextMemory.normalize(left) == NextMemory.normalize(right) { return true }
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        let overlap = Double(lhs.intersection(rhs).count) / Double(lhs.union(rhs).count)
        return overlap >= duplicateOverlap
    }

    /// Why a fact was thrown out, said to a person rather than to a model.
    static func reason(for error: Error) -> String {
        guard let error = error as? MemoryWriteError else { return error.localizedDescription }
        switch error {
        case .blocked(let why):
            // MemoryGuard's own sentence, which already reads plainly.
            return why.prefix(1).uppercased() + why.dropFirst()
        case .notDeclarative:
            return "It tells the assistant what to do instead of saying something about you."
        case .tooLong:
            return "It's longer than one memory can be."
        case .empty:
            return "There was nothing in it."
        default:
            return error.errorDescription ?? "It couldn't be saved."
        }
    }

    /// A dropped line is shown back to the person, so it is clipped — and an injected line is
    /// exactly the kind of text that is long and designed to be read.
    static func preview(_ text: String, limit: Int = 160) -> String {
        let collapsed = NextMemory.collapsedWhitespace(text)
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit)) + "…"
    }
}
