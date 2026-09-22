import Foundation

/// The rule that every backend is filtered through: **a value nobody said is not a value.**
///
/// This exists because the failure it prevents is invisible at the approval card. Ask Needle
/// to "send Marcus the updated pricing sheet" with no address anywhere and it answers
/// `to: "marcus.chen@proton.me"` with confidence 1.0 — a plausible, well-formed, completely
/// invented address. A card that shows it is asking the user to approve a fact, not an
/// action, and nobody reads an address that carefully. So the address is removed here and
/// the argument is reported missing, which turns a silent wrong send into a question.
///
/// Two levels, because they fail differently:
///
/// - **Identity-shaped values** — an email address, a phone number, a URL, a file path, an
///   `@handle`. These have to appear in what was said, character for character (case and
///   punctuation aside). There is no such thing as paraphrasing an address, so a near miss
///   is an invention.
/// - **Everything else** — a subject line, a title, a sentence of body text. These are
///   *meant* to be rewritten, so the test is weaker: at least one meaningful word of the
///   value has to come from the source. That still catches `title: "Weather"` proposed from
///   a sentence about nothing, while letting "Q3 deck" through from "the Q3 deck".
///
/// Dates are the awkward middle. "Tomorrow at three" is grounded and legitimately becomes an
/// ISO timestamp that shares no characters with it, so a date-shaped value is accepted when
/// the source contains any time expression at all, and rejected when it contains none.
enum FunctionCallGrounding {

    /// Applies the rule to one call. Returns the call with invented arguments stripped and
    /// named in `missingArguments`.
    ///
    /// - Parameter flaggedByBackend: argument names the backend itself reported as
    ///   ungrounded. Needle emits these in `validation.ungrounded`; they are always honoured,
    ///   on top of whatever this check finds.
    /// - Parameter utterance: the sentence that triggered this proposal, when there is one.
    ///   Supplied so the echo rule below can run: a value that *is* the request is never the
    ///   content of the request.
    static func filter(
        _ call: ProposedFunctionCall,
        tool: FunctionCallTool?,
        source: String,
        flaggedByBackend: Set<String> = [],
        utterance: String = ""
    ) -> ProposedFunctionCall {
        var filtered = call
        var missing = Set(call.missingArguments)
        let haystack = normalize(source)

        for (name, value) in call.arguments {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                filtered.arguments.removeValue(forKey: name)
                missing.insert(name)
                continue
            }
            let shape = tool?.parameters.first { $0.name == name }?.shape ?? .text
            if flaggedByBackend.contains(name)
                || !hasShape(trimmed, shape)
                || !isGrounded(trimmed, in: haystack)
                || isEcho(trimmed, of: utterance) {
                filtered.arguments.removeValue(forKey: name)
                missing.insert(name)
            }
        }

        // Only *required* absences are worth asking about. An optional argument nobody
        // mentioned is simply not part of the request, and listing it turns every card into
        // a form.
        guard let required = tool?.requiredParameters, !required.isEmpty else {
            filtered.missingArguments = missing.sorted()
            return filtered
        }
        // A required argument is missing whether it was written and stripped here, or never
        // written at all. The second half matters more than it looks: both backends are told
        // "if a value was not said, leave the argument out entirely", so a model that obeys
        // produces a call with no `to` in it — and reporting only what *this* function
        // removed would let that call through with an empty `missingArguments`, claiming to
        // be complete. The card would then show no question and an enabled Approve for a
        // mail with no recipient. The invented-address case is the loud version of this bug;
        // this is the quiet one, and it is the one a well-behaved model produces.
        filtered.missingArguments = required
            .filter { missing.contains($0) || filtered.arguments[$0] == nil }
            .sorted()
        return filtered
    }

    /// Whether the value is the kind of thing the field takes at all.
    ///
    /// Measured, not imagined: asked to "send Marcus the updated pricing sheet" with the
    /// real catalogue, Needle answers `to: "Marcus"` and reports nothing ungrounded, because
    /// the word *is* in the sentence. Grounding is the wrong question for that field. The
    /// right one is whether an email could be addressed with it.
    static func hasShape(_ value: String, _ shape: FunctionCallTool.Shape) -> Bool {
        switch shape {
        case .text, .longText:
            return true
        case .email:
            // Every entry of a comma-separated list has to be an address, not just one.
            let parts = value.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard !parts.isEmpty else { return false }
            return parts.allSatisfy { part in
                guard let at = part.firstIndex(of: "@") else { return false }
                let domain = part[part.index(after: at)...]
                return at != part.startIndex && domain.contains(".") && !domain.hasSuffix(".")
            }
        case .dateTime:
            // "tomorrow at three" is a grounded answer and an unusable one: `gws --dry-run`
            // echoes it back happily and Google refuses it afterwards, by which time the
            // user has already pressed Approve. Asking is cheaper than that.
            return isDateShaped(value)
        case .identifier:
            // An opaque handle: one token, long enough to be an id, and nothing a sentence
            // would contain. A doc *title* fails this on purpose — the executor passes this
            // straight to `docs +write --document`, which takes an id and not a name.
            let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.count >= 8, token.count <= 128 else { return false }
            return token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }

    /// Whether the value is simply the request read back.
    ///
    /// The measured case: "open Google Chrome and go to youtube.com" came back as
    /// `append_doc(document_id: "You open Google Chrome…", text: "You open Google Chrome…")`.
    /// Every other rule passes it — the words are right there, which is exactly what makes
    /// it look grounded. But a command is never the content of the thing it commands: if the
    /// user wanted a sentence written down they said what the sentence was, and a value that
    /// borrows the whole request instead means the model had nothing and filled the field
    /// with the prompt.
    ///
    /// The threshold is high (four fifths of the request's meaningful words) so that a
    /// legitimate short rewrite survives: "Send Marcus the updated pricing sheet" yielding
    /// `subject: "Updated pricing sheet"` shares three of five words and is kept.
    static func isEcho(_ value: String, of utterance: String) -> Bool {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let said = stems(of: trimmed)
        // Nothing meaningful was said, so nothing can be echoed back distinctively.
        guard said.count >= 3 else { return false }
        let borrowed = Set(stems(of: value))
        guard !borrowed.isEmpty else { return false }
        let shared = said.filter { borrowed.contains($0) }.count
        return Double(shared) / Double(said.count) >= 0.8
    }

    /// Significant words with edge punctuation removed.
    ///
    /// `normalize` keeps `.` inside a word, which is right for `sarah@acme.com` and wrong at
    /// a full stop: "youtube.com." and "youtube.com" are the same word, and the echo rule
    /// comparing them as different ones let the 2026-09-20 sentence through with its pronoun
    /// trimmed off — a one-character difference deciding whether a command got written into
    /// a document.
    private static func stems(of text: String) -> [String] {
        significantWords(in: normalize(text)).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-_:"))
        }
        .filter { !$0.isEmpty }
    }

    /// Whether `value` may be used, given the normalized text it should have come from.
    static func isGrounded(_ value: String, in normalizedSource: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Dates first, and not for tidiness: `2026-09-25T09:00:00Z` is 70% digits, so the
        // phone-number heuristic below claims it and then demands a literal match that a
        // timestamp derived from "tomorrow at three" can never satisfy.
        if isDateShaped(trimmed) {
            return normalizedSource.contains(normalize(trimmed)) || containsTimeExpression(normalizedSource)
        }
        if isIdentityShaped(trimmed) {
            return normalizedSource.contains(normalize(trimmed))
        }

        let normalizedValue = normalize(trimmed)
        if normalizedSource.contains(normalizedValue) { return true }

        // A rewritten value: at least one word that carries meaning has to be borrowed.
        let words = significantWords(in: normalizedValue)
        guard !words.isEmpty else {
            // Nothing but stop words and numbers. Accept only a literal match, which the
            // check above already refused.
            return false
        }
        return words.contains { normalizedSource.contains($0) }
    }

    /// An address, a number, a link or a path — a value that cannot be paraphrased.
    static func isIdentityShaped(_ value: String) -> Bool {
        let lowered = value.lowercased()
        if lowered.contains("@") { return true }
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") { return true }
        if lowered.hasPrefix("/") || lowered.hasPrefix("~/") { return true }
        if lowered.contains("www.") { return true }
        // A phone number: mostly digits, at least seven of them.
        let digits = lowered.filter(\.isNumber).count
        if digits >= 7, Double(digits) / Double(max(lowered.count, 1)) > 0.5 { return true }
        return false
    }

    /// `2026-09-21`, `2026-09-21T15:00:00-04:00`, `15:00`.
    static func isDateShaped(_ value: String) -> Bool {
        let scalars = Array(value)
        guard scalars.count >= 5 else { return false }
        let digits = scalars.filter(\.isNumber).count
        guard digits >= 4 else { return false }
        let separators = scalars.filter { $0 == "-" || $0 == ":" || $0 == "/" }.count
        return separators >= 1 && Double(digits + separators) / Double(scalars.count) > 0.5
    }

    /// Any word that says *when*. Deliberately broad: the cost of a false accept here is an
    /// approval card showing a time the user can see and correct, and the cost of a false
    /// reject is an otherwise good proposal losing its one required argument.
    static func containsTimeExpression(_ normalizedSource: String) -> Bool {
        for word in timeWords where normalizedSource.contains(word) { return true }
        // "at 3", "by 10", "in 20 minutes" — a bare number next to a time preposition.
        return normalizedSource.range(
            of: #"\b(at|by|before|after|around|from|until)\s+\d"#,
            options: [.regularExpression]
        ) != nil
    }

    private static let timeWords: [String] = [
        "today", "tomorrow", "tonight", "yesterday", "morning", "afternoon", "evening",
        "noon", "midnight", "monday", "tuesday", "wednesday", "thursday", "friday",
        "saturday", "sunday", "next week", "this week", "next month", "o'clock", "oclock",
        "am", "pm", "hour", "minute", "week", "month", "january", "february", "march",
        "april", "may", "june", "july", "august", "september", "october", "november",
        "december",
    ]

    /// Lowercased, NFC-composed, punctuation flattened to single spaces.
    ///
    /// NFC matters for the same reason it does in the dictionary: macOS hands back decomposed
    /// strings, so an accented name in a transcript would never match the same name written
    /// by a model that composed it.
    static func normalize(_ text: String) -> String {
        let composed = text.precomposedStringWithCanonicalMapping.lowercased()
        var out = String()
        out.reserveCapacity(composed.count + 2)
        var lastWasSpace = true
        for character in composed {
            if character.isLetter || character.isNumber || character == "@" || character == "."
                || character == "-" || character == "_" || character == "/" || character == ":"
                || character == "+" {
                out.append(character)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return " " + out.trimmingCharacters(in: .whitespaces) + " "
    }

    /// Words worth borrowing: four letters or more, and not a filler.
    static func significantWords(in normalizedValue: String) -> [String] {
        normalizedValue
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 4 && !stopWords.contains($0) }
    }

    private static let stopWords: Set<String> = [
        "this", "that", "with", "from", "they", "them", "there", "here", "have", "will",
        "would", "could", "should", "about", "please", "thanks", "thank", "your", "yours",
        "been", "were", "what", "when", "which", "their", "some", "just", "like", "also",
        "into", "over", "then", "than", "made", "make", "does", "done", "very", "much",
    ]
}
