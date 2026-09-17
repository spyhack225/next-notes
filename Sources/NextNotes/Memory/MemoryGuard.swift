import Foundation

/// Where a memory write came from, set by the code that runs the turn — never by the model.
///
/// The tool loop binds this around each tool call with `MemoryProvenance.$current`. The
/// memory tools read it, so a model's claim that "the user said this" carries no weight:
/// what counts is the user's own words this turn and the tool output the turn has seen.
struct MemoryProvenance: Sendable {
    enum Origin: String, Sendable {
        /// The user's own conversation with the Agent (typed or spoken).
        case userConversation
        /// The background memory review reading what the user said (Part 2, M2).
        case memoryReview
    }

    let origin: Origin
    let sessionID: UUID?
    /// What the user said: the current request and their recent turns.
    let userText: [String]
    /// Everything that is not the user's words and reached this turn: tool results, earlier
    /// tool-backed answers. Emails, pages, files and calendar descriptions all land here.
    let untrustedText: [String]
    /// A tool outside `memory` and `schedule` returned output earlier in this turn. A
    /// reminder written after that asks with a card (`ScheduleConfirmation`).
    var readToolOutputThisTurn = false

    @TaskLocal static var current: MemoryProvenance?

    /// The authority a write under this provenance must also carry in the action runtime.
    var requiredAuthority: ActionAuthority {
        switch origin {
        case .userConversation: .user
        case .memoryReview: .memoryReview
        }
    }
}

/// Auto-saving means the guards are the feature.
///
/// 1. **Provenance.** A memory is created only from what the user said — never from an
///    email, web page, file, calendar description or any tool result.
/// 2. **Memory never grants permission.** An entry that claims or implies an authorisation is
///    refused; grants live in `permission-grants.json` and only the user creates them.
/// 3. **Injection scan on write and on load.** Instruction overrides, role reassignment,
///    exfiltration phrasing and invisible Unicode. Ordinary firm English ("you must") passes.
///
/// Hermes Agent's `threat_patterns.py` is the reference for the pattern set.
enum MemoryGuard {
    struct Finding: Equatable, Sendable {
        enum Category: String, Sendable {
            case invisibleUnicode
            case injection
            case exfiltration
            case permission
        }
        let category: Category
        let reason: String
    }

    // MARK: - Content scan

    /// The first problem with `text`, or nil when it may be stored and injected.
    static func scan(_ text: String) -> Finding? {
        if let scalar = invisibleScalar(in: text) {
            return Finding(category: .invisibleUnicode, reason: String(
                format: "it contains an invisible character (U+%04X).", scalar.value))
        }
        // Compatibility folding first, so fullwidth or styled letters cannot dodge a pattern.
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: "’", with: "'")
        for pattern in injectionPatterns where matches(pattern, folded) {
            return Finding(category: .injection,
                           reason: "it reads like an instruction to the Agent rather than a fact.")
        }
        for pattern in exfiltrationPatterns where matches(pattern, folded) {
            return Finding(category: .exfiltration,
                           reason: "it asks for information to be sent somewhere.")
        }
        for pattern in permissionPatterns where matches(pattern, folded) {
            return Finding(category: .permission,
                           reason: "memory can't grant permission. Choose what runs without asking in "
                               + "Settings → Agent.")
        }
        return nil
    }

    /// Zero-width, bidirectional-override, tag and other format characters, and control
    /// characters. Refused rather than stripped: their presence is the signal. The joiner and
    /// variation selector inside an emoji sequence (❤️, 👨‍👩‍👧) are how emoji are spelled, not hiding.
    static func invisibleScalar(in text: String) -> Unicode.Scalar? {
        let scalars = Array(text.unicodeScalars)
        func isPictograph(_ index: Int) -> Bool {
            scalars.indices.contains(index) && scalars[index].value >= 0x2000 && scalars[index].properties.isEmoji
        }
        for (index, scalar) in scalars.enumerated() {
            if scalar.value == 0xFE0F, isPictograph(index - 1) { continue }
            if scalar.value == 0x200D, isPictograph(index + 1) {
                let before = index >= 2 && scalars[index - 1].value == 0xFE0F ? index - 2 : index - 1
                if isPictograph(before) { continue }
            }
            if isInvisible(scalar) { return scalar }
        }
        return nil
    }

    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B...0x180F,
             0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F, 0x3164, 0xFE00...0xFE0F,
             0xFEFF, 0xFFA0, 0xFFF9...0xFFFB, 0x1D173...0x1D17A, 0xE0000...0xE0FFF:
            return true
        default:
            switch scalar.properties.generalCategory {
            case .control, .format, .privateUse, .unassigned, .surrogate: return true
            default: return false
            }
        }
    }

    private static let injectionPatterns = [
        #"\b(ignore|disregard|forget|override|bypass|skip)\b[^.]{0,40}\b(previous|prior|above|earlier|preceding|all|any|your|the|system|safety)\b[^.]{0,20}\b(instructions?|rules?|prompts?|guidelines?|directives?|guardrails?)\b"#,
        #"\b(ignore|disregard|forget)\b[^.]{0,20}\b(everything|all|anything)\b[^.]{0,20}\b(above|before|earlier|previously|prior)\b"#,
        #"\b(assistant|agent|ai|model)\b[^.]{0,40}\b(ignore|disregard|bypass|break)\b[^.]{0,30}\b(rules|instructions|guidelines|guardrails|safety)\b"#,
        #"\byou are now\b"#,
        #"\bfrom now on,? (you|the assistant|the agent)\b"#,
        #"\b(act|behave|respond|roleplay) as (if you were |an? |the )?(unrestricted|unfiltered|jailbroken|dan|developer|admin|administrator|root|system|different)\b"#,
        #"\bpretend (that )?(you|to be)\b"#,
        #"\bnew (system )?(instructions?|rules?|persona)\s*:"#,
        #"\b(system|developer) (prompt|message|instructions?)\b"#,
        #"\b(developer|god|jailbreak|dan|admin|debug) mode\b"#,
        #"<\|?\s*(im_start|im_end|system|endoftext|eot_id|start_header_id)\s*\|?>"#,
        #"</?\s*(system|assistant|user|tool_call|tool_response|instructions?)\s*>"#,
        #"^\s*(system|assistant|developer)\s*:"#,
        #"\b(reveal|print|repeat|show)\b[^.]{0,20}\b(system prompt|your instructions|hidden instructions)\b"#,
        #"\bthese (rules|instructions) (override|replace|supersede)\b"#,
    ]

    private static let exfiltrationPatterns = [
        #"\b(send|sends|sent|sending|forward\w*|e-?mail\w*|upload\w*|post\w*|shar\w*|cop(y|ies|ied)|leak\w*|exfiltrat\w*|transmit\w*|bcc|cc)\b[^.]{0,80}\b(to|at|with)\s+\S+@\S+\.[a-z]{2,}"#,
        #"\b(send|sends|sent|sending|forward\w*|upload\w*|post\w*|leak\w*|exfiltrat\w*|transmit\w*|submit\w*)\b[^.]{0,80}\bhttps?://"#,
        #"\b(curl|wget|nc|netcat)\s+\S*(https?://|\d+\.\d+\.\d+\.\d+)"#,
        #"\b(send|forward|share|post|upload|reveal|include|paste)\b[^.]{0,40}\b(api[_ -]?keys?|passwords?|passcodes?|credentials|secrets?|private keys?|access tokens?|ssh keys?)\b"#,
        #"\b(api[_ -]?keys?|passwords?|credentials|secrets?|private keys?|access tokens?)\b[^.]{0,40}\b(send|forward|share|post|upload)\b"#,
    ]

    private static let permissionPatterns = [
        // Authorisation aimed at the Agent or the app. "The user's manager gave approval for
        // the offsite" is a fact about the user's world and passes.
        #"\b(agent|assistant|app|next notes|you)\b[^.]{0,30}\b(has|have|had|with|given|granted|gets)\b[^.]{0,30}\b(permission|authori[sz]ation|consent|approval|clearance)\b"#,
        #"\b(gave|gives|give|given|grants?|granted|giving)\b[^.]{0,20}\b(the )?(agent|assistant|app|next notes|you)\b[^.]{0,30}\b(permission|authori[sz]ation|consent|approval|clearance)\b"#,
        #"\b(pre-?approved|pre-?authori[sz]ed|auto-?approved?|standing (approval|authori[sz]ation|permission))\b"#,
        #"\b(agent|assistant|app|next notes|you)\b[^.]{0,30}\b(allowed|authori[sz]ed|permitted|approved|cleared)\s+to\s+(send|delete|forward|run|execute|pay|transfer|buy|purchase|post|publish|share|click|type|act|modify|write|move|remove|email|reply|book|accept|sign)\b"#,
        #"\bwithout (asking|approval|confirmation|permission|confirming|checking|a prompt|prompting)\b"#,
        #"\b(no need|doesn't need|does not need|don't need|do not need|never needs?) to (ask|confirm|check|approve)\b"#,
        #"\b(don't|do not|never|stop) (ask|asking|confirm|confirming|prompt|prompting)\b[^.]{0,20}\b(permission|approval|confirmation|before)\b"#,
        #"\b(skip|bypass|disable) (the )?(approval|confirmation|permission)"#,
    ]

    // MARK: - Declarative, not imperative

    /// "Always answer briefly" re-read in a later session is a command in the wrong context;
    /// "The user prefers brief answers" is weighed as information.
    static func isDeclarative(_ text: String) -> Bool {
        let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let words = lowered.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        guard let first = words.first else { return false }
        if imperativeOpeners.contains(first) { return false }
        let openingPair = words.prefix(2).joined(separator: " ")
        return !["you must", "you should", "you will", "you need", "you have", "you are",
                 "you can", "you may", "you shall", "you'll"].contains(openingPair)
    }

    private static let imperativeOpeners: Set<String> = [
        "always", "never", "do", "don't", "dont", "ignore", "stop", "remember", "make", "ensure",
        "use", "send", "call", "reply", "answer", "respond", "be", "avoid", "please", "forget",
        "tell", "say", "speak", "write", "keep", "only", "must", "should", "note", "save",
        "treat", "consider", "assume", "act", "pretend", "obey", "follow",
    ]

    // MARK: - Provenance

    /// Why a write under `provenance` may not be saved, or nil.
    enum ProvenanceProblem: Equatable, Sendable {
        /// No provenance, or a word, address or name that reached the turn only as tool
        /// output. Never recoverable: the model does not get to try a variation.
        case refused(String)
        /// Too much of it is the model's wording rather than the user's. The model may
        /// retry in the user's own words.
        case notUserWords(String)

        var reason: String {
            switch self {
            case .refused(let reason), .notUserWords(let reason): reason
            }
        }
    }

    /// Nil when the text may be saved under `provenance`, otherwise why not.
    ///
    /// The check is lexical and deliberately conservative. Every content word must be one the
    /// user said (or one already in a stored memory, which the user said when it was saved),
    /// allowing one paraphrased word in four. Any unsupported word found in tool output
    /// refuses the write — one injected word can be the whole fact — as does an address, a
    /// number or a name the user never said.
    static func provenanceProblem(
        _ text: String, provenance: MemoryProvenance?, remembered: [String] = []
    ) -> ProvenanceProblem? {
        guard let provenance else {
            return .refused("memory can only be saved from what you say in a conversation with the Agent.")
        }
        let content = contentTokens(text)
        guard !content.isEmpty else { return .notUserWords("there is no fact in it to remember.") }
        let userTokens = Set((provenance.userText + remembered).flatMap(tokens))
        let untrustedTokens = Set(provenance.untrustedText.flatMap(tokens))

        let unsupported = content.filter { !supports(userTokens, $0) }
        let fromTools = unsupported.filter { supports(untrustedTokens, $0) }
        if !fromTools.isEmpty {
            return .refused("it comes from tool output (an email, page, file or calendar item), not from you.")
        }
        if unsupported.contains(where: isAddressLike) {
            return .refused("it names an address or link you didn't say.")
        }
        let names = properNouns(text)
        if unsupported.contains(where: { $0.contains(where: \.isNumber) || names.contains($0) }) {
            return .refused("it names something you didn't say.")
        }
        let supportedRatio = Double(content.count - unsupported.count) / Double(content.count)
        if unsupported.count > 1 || supportedRatio < 0.75 {
            return .notUserWords("it isn't what you said. Save the fact in the user's own words.")
        }
        return nil
    }

    /// Nil when `memory.forget` or `memory.update` may act on `entry` under `provenance`.
    ///
    /// The match is chosen by the model, so an email saying "forget what you know about X"
    /// could otherwise delete a memory. What the user said must name the entry: for a forget,
    /// a content word of it plus a request to drop or correct something; for an update, a
    /// content word of it in the user's words or in the replacement (which already passed
    /// `provenanceProblem`), so "I moved to Lyon" can replace "The user lives in Paris."
    static func targetProblem(
        _ entry: String, provenance: MemoryProvenance?, replacement: String? = nil
    ) -> String? {
        guard let provenance else {
            return "memory can only be changed from a conversation with the Agent."
        }
        let userTokens = Set((provenance.userText + [replacement ?? ""]).flatMap(tokens))
        guard contentTokens(entry).contains(where: { supports(userTokens, $0) }) else {
            return "you didn't say which memory to change."
        }
        guard replacement == nil else { return nil }
        // The conversation's current request comes first; the review reads the whole exchange.
        let asked = provenance.origin == .userConversation
            ? Array(provenance.userText.prefix(1)) : provenance.userText
        let askedWords = Set(asked.flatMap { $0.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init) })
        guard !askedWords.isDisjoint(with: forgetCues) else {
            return "you didn't ask to forget it."
        }
        return nil
    }

    private static let forgetCues: Set<String> = [
        "forget", "remove", "delete", "drop", "erase", "clear", "wrong", "incorrect", "not", "no",
        "longer", "anymore", "don't", "doesn't", "isn't", "stop", "stopped", "instead", "actually",
        "changed", "outdated", "untrue", "false",
    ]

    /// Capitalised words other than a sentence's first, as lowercased tokens: names a model
    /// could add ("Serge is vegetarian") that the user never said.
    private static func properNouns(_ text: String) -> Set<String> {
        var result: Set<String> = []
        var sentenceStart = true
        for word in text.split(whereSeparator: \.isWhitespace) {
            let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
            if !sentenceStart, let first = trimmed.first, first.isUppercase {
                result.formUnion(tokens(trimmed))
            }
            sentenceStart = word.last.map { ".!?".contains($0) } ?? false
        }
        return result
    }

    /// Words of three or more characters, plus anything with a digit or an address shape.
    static func tokens(_ text: String) -> [String] {
        let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'")
        var result: [String] = []
        var current = ""
        func flush() {
            var token = current.trimmingCharacters(in: CharacterSet(charactersIn: ".-_'@/:"))
            if token.hasSuffix("'s") { token.removeLast(2) }
            if token.count >= 3 || token.contains(where: \.isNumber) { result.append(token) }
            current = ""
        }
        for character in lowered {
            if character.isLetter || character.isNumber || "@._-'/:".contains(character) {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    static func contentTokens(_ text: String) -> [String] {
        tokens(text).filter { !scaffolding.contains($0) }
    }

    private static func isAddressLike(_ token: String) -> Bool {
        token.contains("@") || token.contains("://") || token.hasPrefix("www.")
            || token.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)*\.(com|net|org|io|co|ai|dev|app|me|us|uk|de|fr)$"#,
                           options: .regularExpression) != nil
    }

    /// Exact, or a shared stem for inflections ("prefer"/"prefers", "answer"/"answers").
    /// Addresses and numbers must match exactly.
    private static func supports(_ pool: Set<String>, _ token: String) -> Bool {
        if pool.contains(token) { return true }
        if isAddressLike(token) || token.contains(where: \.isNumber) { return false }
        guard token.count >= 4 else { return false }
        let wanted = stem(token)
        return pool.contains { candidate in
            candidate.count >= 4 && !isAddressLike(candidate) && stem(candidate) == wanted
        }
    }

    private static func stem(_ token: String) -> String {
        var word = token
        if word.count > 4, word.hasSuffix("s") { word.removeLast() }
        return String(word.prefix(5))
    }

    /// The declarative frame a model wraps around a fact, which the user need not have said.
    private static let scaffolding: Set<String> = [
        "the", "user", "users", "user's", "their", "they", "them", "theirs", "themselves",
        "prefer", "prefers", "preferred", "preference", "likes", "like", "liked", "wants", "want",
        "wanted", "wishes", "and", "but", "for", "from", "with", "without", "about", "into",
        "onto", "that", "this", "these", "those", "which", "who", "whom", "whose", "what",
        "when", "where", "while", "has", "have", "had", "was", "were", "are", "is", "been",
        "being", "does", "did", "not", "should", "would", "could", "can", "will", "shall", "may",
        "might", "must", "always", "usually", "often", "generally", "typically", "also", "very",
        "called", "named", "name", "known", "goes", "his", "her", "him", "she", "its", "our",
        "you", "your", "yours", "mine", "myself", "remember", "remembers", "note", "notes",
        "noted", "fact", "rather", "than", "then", "there", "here", "any", "all", "some", "one",
        "get", "gets", "got", "make", "makes", "made", "keep", "keeps", "use", "uses", "used",
        "via", "per", "each", "every", "more", "most", "less", "much", "many", "such", "just",
        "only", "still", "yet", "own", "same", "other", "agent", "next",
    ]

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
