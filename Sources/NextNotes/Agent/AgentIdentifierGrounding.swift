import Foundation

/// An id in an action has to come from something the person was shown or something they said.
///
/// On 20 September an `append_doc` was proposed with the document id **"You open Google Chrome"**
/// — a fragment of the person's own sentence. It was approved about eight seconds later, and Google
/// then rejected it. That was the only Workspace write ever approved on this Mac, and it failed for
/// a reason that was visible before the card ever appeared.
///
/// The meeting side already refuses this class of mistake: `FunctionCallGrounding.groundedArguments`
/// keeps only the values a source supports and `MeetingAgent` rejects what is left. The tool loop has
/// its own `groundedArguments`, and **neither of them looked at an id** — because an id has no shape
/// to check. `"Marcus"` is not an address and grounding is the wrong question for it; a document id is
/// not a word at all, and the question is not what it *is* but whether anyone ever *said* it.
///
/// So this is a different check, not a stricter one, and it is deliberately narrow:
///
/// - **Only parameters the catalogue marks `.identifier`.** Never guessed from a name; the mark is
///   on the parameter, next to its description, where the person writing the tool says what it is.
/// - **Only before the approval card.** A card that shows an ungrounded id is the failure; the
///   refusal happens first, and it comes back as a **tool result** rather than as prose, because a
///   tool result is what the model reads on the next round and a note in prose is what P1-14
///   measured to be ignored.
/// - **Reuses `FunctionCallGrounding`'s matcher.** `normalize` and `isGrounded` are one
///   implementation of "appeared verbatim, word-bounded"; a third matcher beside them is how two
///   answers to "is this supported?" become two answers.
enum AgentIdentifierGrounding {
    /// The one sentence the model reads, and it is different per kind because a document and a
    /// message number are looked up differently. Plain words, no id, no tool name.
    static func notFoundSentence(parameter: String, toolID: String) -> String {
        let subject: String
        if parameter == "message" {
            subject = "That message"
        } else if parameter.hasSuffix("_id") {
            subject = "That " + parameter.replacingOccurrences(of: "_id", with: "")
        } else {
            subject = "That " + parameter
        }
        return "\(subject) hasn't been found yet — look it up first, then use the exact id it gives you."
    }

    /// The one refusal for a whole call, and the place the audit row is written from.
    struct Refusal: Equatable {
        let parameter: String
        let value: String
        let sentence: String
    }

    /// Every `.identifier` parameter in `arguments` that no source supports.
    ///
    /// - Parameter haystack: everything the conversation has shown the person plus what they said
    ///   — `AgentSession.groundingHaystack()`. One string, because the matcher is one substring
    ///   test and two haystacks would be two chances to disagree about what was in scope.
    static func ungrounded(
        toolID: String, arguments: [String: String], haystack: String
    ) -> [Refusal] {
        let normalizedSource = FunctionCallGrounding.normalize(haystack)
        return identifierParameterNames(of: toolID).compactMap { name in
            // The value comes from the *arguments*, not from the name list. An earlier version
            // paired the two names here with a placeholder value and the empty-value check below
            // then skipped every parameter — so the guard checked nothing at all and looked
            // green. `--selftest-toolloop-production`'s I1 caught it, by crashing rather than
            // failing cleanly, which is the worst way to be caught and the reason the case now
            // reads a named binding instead of an index.
            guard let value = arguments[name] else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return nil }
            // Reused, not reimplemented. `isGrounded` is the same verbatim word-bounded test the
            // meeting side and the second `groundedArguments` already use, and a third one
            // beside them is exactly the drift this file is here to stop.
            //
            // Its **last** branch allows a paraphrase — one significant word borrowed from the
            // source is enough — and that is right for an email address in a sentence and wrong
            // for an id, which is either said or it is not. So the test here is the strict
            // branch: the value must appear in the normalized source **whole**. The 20 September
            // failure is what that catches: "You open Google Chrome" borrows nothing, and a rule
            // that allowed one shared word would have to allow a fragment of a sentence.
            let normalizedValue = FunctionCallGrounding.normalize(trimmed)
            guard normalizedSource.contains(normalizedValue) == false else { return nil }
            return Refusal(parameter: name, value: trimmed,
                           sentence: notFoundSentence(parameter: name, toolID: toolID))
        }
    }

    static func identifierParameterNames(of toolID: String) -> [String] {
        guard let entry = WorkspaceTools.tool(named: toolID) else { return [] }
        return entry.parameters.filter { $0.kind == .identifier }.map(\.name)
    }

    /// The whole-call answer: the first refusal, as the note the next round reads.
    ///
    /// One refusal rather than a list, because a model that is handed three corrections writes
    /// prose. The others are in the audit row, which is where a person looks.
    static func note(for refusal: Refusal) -> String {
        ToolRepair(kind: .ungroundedIdentifier, message: refusal.sentence).modelText
    }
}
