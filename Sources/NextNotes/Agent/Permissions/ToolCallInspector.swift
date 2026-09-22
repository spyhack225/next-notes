import Foundation

/// Decides whether one value is real.
///
/// Three different failures look identical on a card that only prints the arguments:
///
/// 1. **Missing.** The model left `to` out entirely, or wrote an empty string.
/// 2. **A placeholder.** `[Name]`, `TBD`, `john.doe@example.com`, `(555) 555-0134`,
///    `<insert date>`. These are training-data furniture, not answers, and they are the
///    ones that reach a real inbox looking like a real message.
/// 3. **Invented.** A perfectly well-formed address, name, or date that appears nowhere in
///    what the user said, the transcript, the invite, memory or the people the app knows.
///    This is the failure the user described: "it is really faking information".
///
/// The first two are decidable from the string alone. The third needs the haystack, which
/// is why grounding takes a `ToolCallContext`. Nothing here rewrites a value — an inspector
/// that "fixed" a placeholder would be inventing in the app instead of in the model.
enum ToolCallInspector {

    // MARK: - Placeholders

    /// Whole values that are stand-ins however they are capitalised.
    private static let standIns: Set<String> = [
        "tbd", "tba", "tbc", "todo", "to do", "to be decided", "to be determined",
        "unknown", "unspecified", "not specified", "none", "n/a", "na", "null", "nil",
        // "test" is deliberately absent: it is a perfectly ordinary thing to search for.
        "undefined", "placeholder", "example", "xxx", "xxxx", "???", "-", "--",
        "name", "recipient", "recipient name", "your name", "email", "email address",
        "subject", "body", "insert", "fill in", "string", "value", "pending",
    ]

    /// Fragments that give a stand-in away wherever they appear inside a value, including
    /// inside a long message body — "Hi [Name]," must never be sent.
    private static let standInFragments: [String] = [
        "john.doe", "jane.doe", "johndoe", "janedoe", "john doe", "jane doe",
        "yourname", "your.name", "your name@", "someone@", "user@", "email@",
        "recipient@", "name@email", "firstname", "lastname", "lorem ipsum",
        "[insert", "insert your", "insert name", "insert date", "your company",
        "xxx-xxx", "555-555", "555-0",
    ]

    /// Domains that exist to be written down rather than delivered to.
    private static let documentationDomains: [String] = [
        "example.com", "example.org", "example.net", "example.edu",
        "domain.com", "yourdomain.com", "mycompany.com",
    ]

    /// Local parts that name a role rather than a person.
    private static let genericLocalParts: Set<String> = [
        "name", "firstname", "lastname", "first", "last", "user", "username",
        "someone", "somebody", "recipient", "receiver", "person", "contact",
        "email", "mail", "address", "example", "placeholder",
        "yourname", "your", "me", "you", "abc", "xyz", "foo", "bar",
    ]

    /// `john.doe@example.com` is furniture; `sam@example.com` may well be the address in
    /// somebody's own calendar invite.
    ///
    /// A documentation domain is the first thing a model reaches for when it does not know
    /// an address, so the temptation is to refuse all of them outright. That refusal is
    /// wrong twice over: it rejects a real invite that happens to use one — several of this
    /// app's own fixtures do — and it does nothing at all about `sarah.jones@acme.co`
    /// invented out of thin air. So the string check catches only what is furniture
    /// whatever the haystack says: a role-shaped local part on a documentation domain.
    /// Everything else goes to grounding, where an address nothing confirms is reported as
    /// "not confirmed" instead of as fact.
    private static func isFurnitureAddress(_ address: String) -> Bool {
        let lowered = address.lowercased()
        guard let at = lowered.firstIndex(of: "@") else { return false }
        let local = String(lowered[lowered.startIndex..<at])
        let domain = String(lowered[lowered.index(after: at)...])
        guard documentationDomains.contains(where: { domain == $0 || domain.hasSuffix(".\($0)") })
        else { return false }
        if genericLocalParts.contains(local) { return true }
        let parts = local.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" }).map(String.init)
        return parts.count > 1 && parts.allSatisfy { genericLocalParts.contains($0) }
    }

    /// `[Name]`, `<name>`, `{name}`, `{{name}}`, `___`. The bracket forms are how every
    /// small model writes "I do not know this yet" while still emitting a valid argument.
    private static let templateMarker = #"(\[[^\]\n]{1,60}\])|(\{\{?[^}\n]{1,60}\}?\})|(<[A-Za-z][^>\n]{0,60}>)|(_{3,})"#

    /// Parameters whose value is content the user supplies verbatim rather than a slot the
    /// model has to know the answer to.
    ///
    /// The stand-in list is a list of words a model writes when it does not know something,
    /// and it is also a list of perfectly ordinary things to search for and to type. "Find
    /// files with todo in them" is `filesystem.search` with `query: "todo"`; a web form's
    /// dropdown really does have an option called "None"; "N/A" is a real answer to type
    /// into a field. Refusing those is the app inventing a problem, so the whole-value list
    /// is not applied to them — anything actually unverifiable in them is still labelled by
    /// grounding, which is a sentence on the card rather than a refusal.
    private static let verbatimParameters: Set<String> = [
        "query", "text", "value", "content", "keys", "search", "term", "q",
    ]

    /// Stand-ins that are furniture whatever tool they belong to and whatever the parameter
    /// is called: a template marker, a documentation address, the reserved 555 range, "Hi
    /// [Name],". Decidable from the string alone, which is what lets the parser — which has
    /// not looked the tool up yet — drop them.
    static func isUniversalStandIn(_ value: String, kind: ToolCallFieldKind = .text) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()

        if standInFragments.contains(where: { lowered.contains($0) }) { return true }
        if emails(in: trimmed).contains(where: isFurnitureAddress) { return true }
        // A 555-01xx number is the reserved fictional range, and models reach for it.
        if lowered.range(of: #"\b555[-.\s]?01\d{2}\b"#, options: .regularExpression) != nil { return true }

        // An angle-bracket marker inside prose is fine (`<b>`, `a < b`); a bracket marker
        // is not. For a one-line field any template marker is disqualifying.
        if trimmed.range(of: templateMarker, options: .regularExpression) != nil {
            if kind == .longText {
                // In a body, only the square/curly forms — an HTML-ish `<p>` should not
                // block a message the user is about to read anyway.
                return trimmed.range(of: #"(\[[^\]\n]{1,60}\])|(\{\{?[^}\n]{1,60}\}?\})|(_{3,})"#,
                                     options: .regularExpression) != nil
            }
            return true
        }
        return false
    }

    /// Whether this value is furniture rather than an answer.
    ///
    /// `risk` and `name` decide whether the whole-value list applies at all. It is a list of
    /// words meaning "I do not know", so it belongs to a slot that names something in the
    /// world — a recipient, a date, a file — or to an action that cannot be taken back. On a
    /// lookup's search box it would refuse the user's own question.
    static func isPlaceholder(
        _ value: String,
        kind: ToolCallFieldKind,
        risk: AgentRisk = .send,
        name: String? = nil
    ) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isUniversalStandIn(trimmed, kind: kind) { return true }

        let isVerbatim = name.map { verbatimParameters.contains($0.lowercased()) } ?? false
        guard kind.isFactual || (risk > .read && !isVerbatim) else { return false }

        let lowered = trimmed.lowercased()
        if standIns.contains(lowered) { return true }
        // A comma-separated list of stand-ins is a stand-in: "TBD, unknown".
        let parts = lowered.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count > 1 && parts.allSatisfy { standIns.contains($0) }
    }

    /// The whole verdict for one field.
    static func problem(
        value: String,
        isRequired: Bool,
        kind: ToolCallFieldKind,
        provenance: ToolCallProvenance,
        unverified: [String],
        risk: AgentRisk = .send,
        name: String? = nil
    ) -> ToolCallFieldProblem? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return isRequired ? .missing : nil }
        // A placeholder blocks whether or not the field was required: an optional field
        // carrying "[Name]" still puts "[Name]" in front of a real person.
        if isPlaceholder(trimmed, kind: kind, risk: risk, name: name) { return .placeholder }
        if !unverified.isEmpty { return .notConfirmed }
        if provenance == .inferred, kind.isFactual { return .notConfirmed }
        return nil
    }

    // MARK: - Grounding

    /// Every factual token inside a value that nothing in `context` confirms.
    ///
    /// Empty means "everything checkable here checks out" — which is not the same as
    /// "there was nothing to check", so callers also look at `provenance`.
    static func unverifiedTokens(
        in value: String,
        kind: ToolCallFieldKind,
        context: ToolCallContext
    ) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var unverified: [String] = []

        // Addresses, wherever they sit — a body that signs off with an invented address is
        // the same failure as an invented `to`.
        for address in emails(in: trimmed) where !context.confirmsEmail(address) {
            unverified.append(address)
        }
        // Phone numbers inside prose. A number nobody said is a number nobody can call.
        // Not in a timestamp field: `2026-09-09T13:40:00-04:00` is digits and hyphens in
        // the same shape as a phone number, and reporting the date as an unconfirmed
        // number sends the user looking for a contact detail that was never there.
        if kind != .dateTime {
            for number in phoneNumbers(in: trimmed) where !context.confirmsNumber(number) {
                unverified.append(number)
            }
        }

        switch kind {
        case .email:
            // A recipient that is a bare name rather than an address still has to be someone.
            if emails(in: trimmed).isEmpty {
                for name in listItems(trimmed) where !context.confirmsPerson(name) {
                    unverified.append(name)
                }
            }
        case .person:
            for name in listItems(trimmed) where !context.confirmsPerson(name) {
                unverified.append(name)
            }
        case .dateTime:
            if !context.confirmsDate(trimmed) { unverified.append(trimmed) }
        case .file:
            if !context.confirmsFile(trimmed) { unverified.append(trimmed) }
        case .choice, .text, .longText:
            break
        }

        var seen = Set<String>()
        return unverified.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Where a value came from, once it is known to be neither empty nor a placeholder.
    static func provenance(
        for value: String,
        kind: ToolCallFieldKind,
        unverified: [String],
        context: ToolCallContext
    ) -> ToolCallProvenance {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .missing }
        // Anything checkable has already been checked, by the rule that fits it: an address
        // against the addresses, a date against the ways a person actually says one out
        // loud. Deciding it again here on a literal string match would call every
        // well-formed timestamp invented, because nobody speaks in RFC 3339.
        if !unverified.isEmpty { return .inferred }
        if context.userSaid(trimmed) { return .userSaid }
        if context.contextHas(trimmed) { return .fromContext }
        // A factual value that survived its own check is grounded even when those exact
        // characters appear nowhere. Prose that survived nothing — a subject line, a
        // message body — is the agent's own writing, which is its job; the card says so
        // rather than passing it off as something somebody said.
        return kind.isFactual ? .fromContext : .inferred
    }

    // MARK: - Scanning

    private static let emailPattern = #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
    private static let phonePattern = #"(?<!\d)(\+?\d[\d\-.\s()]{6,}\d)(?!\d)"#

    static func emails(in text: String) -> [String] {
        matches(of: emailPattern, in: text)
    }

    static func phoneNumbers(in text: String) -> [String] {
        matches(of: phonePattern, in: text)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.filter(\.isNumber).count >= 7 }
            // A date written out is not a number anyone can ring, and a body that mentions
            // one would otherwise be reported as carrying an unconfirmed phone number.
            .filter { $0.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) == nil }
    }

    /// A comma-separated field split into the values a runner would pass as separate flags.
    static func listItems(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let found = Range(match.range, in: text) else { return nil }
            return String(text[found])
        }
    }
}
