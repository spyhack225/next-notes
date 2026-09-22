import Foundation

/// Everything the app can check a proposed value against, flattened into one value type.
///
/// It exists so the inspector is a pure function: the real sources — the live transcript,
/// the invite, `NextMemory`, the knowledge graph's resolved people — are all `@MainActor`
/// singletons, and a rule that reached into them could only be exercised with a meeting, a
/// model and an account. `ToolCallContextBuilder` gathers them once on the main actor;
/// everything downstream sees this.
///
/// Matching is deliberately generous about *form* and strict about *substance*: text is
/// NFC-normalised and diacritic-folded, because macOS hands back decomposed strings and a
/// transcript saying "Zoé" must confirm an argument saying "Zoe". It is never generous
/// about presence — a value that is not in here is reported as unconfirmed, full stop.
struct ToolCallContext: Sendable, Equatable, Codable {
    /// What the user themselves said or typed for this turn.
    var userWords: String = ""
    /// The meeting transcript, or the recent window of it.
    var transcript: String = ""
    /// The notes written from the meeting.
    var notes: String = ""
    /// Names and addresses off the calendar invite.
    var attendees: [String] = []
    /// People the app knows: resolved graph people, named speakers, contacts.
    var people: [String] = []
    /// Addresses the app has seen before.
    var knownEmails: [String] = []
    /// What memory holds, as text.
    var memory: String = ""
    /// Files already named in this conversation, as paths.
    var files: [String] = []
    /// The device clock, for "tomorrow".
    var now: Date = Date()

    static let empty = ToolCallContext()

    // MARK: - Haystacks

    /// The raw text behind each haystack. Folding and tokenising it is the expensive part,
    /// so it happens once per distinct text in `ToolCallHaystack.folded(_:)` rather than
    /// once per question — a real transcript on this machine is 110 KB, and a card asks
    /// four to six questions.
    private var contextSource: String {
        ([transcript, notes, memory] + attendees + people + knownEmails + files)
            .joined(separator: "\n")
    }

    private var userHaystack: ToolCallHaystack { ToolCallHaystack.folded(userWords) }

    private var contextHaystack: ToolCallHaystack { ToolCallHaystack.folded(contextSource) }

    private var everything: ToolCallHaystack {
        ToolCallHaystack.folded(userWords + "\n" + contextSource)
    }

    // MARK: - Questions the inspector asks

    /// The value, or every significant word in it, is in what the user said.
    func userSaid(_ value: String) -> Bool { Self.contains(value, in: userHaystack) }

    /// The value is somewhere the app can point at that is not the user's own words.
    func contextHas(_ value: String) -> Bool { Self.contains(value, in: contextHaystack) }

    /// An address is confirmed only as itself. A name that was said is not permission to
    /// invent the domain it belongs to, which is exactly how `marie@acme.com` gets written
    /// for a Marie whose address nobody has ever seen.
    func confirmsEmail(_ address: String) -> Bool {
        let folded = Self.fold(address)
        if knownEmails.contains(where: { Self.fold($0) == folded }) { return true }
        if attendees.contains(where: { Self.fold($0).contains(folded) }) { return true }
        // An address is distinctive enough that a literal appearance anywhere is a real
        // sighting, which is not true of a bare word — see `contains(_:in:)`.
        return everything.text.contains(folded)
    }

    /// A person is confirmed when their name, or every part of it, was said or is someone
    /// the app already knows.
    func confirmsPerson(_ name: String) -> Bool {
        let folded = Self.fold(name)
        guard !folded.isEmpty else { return false }
        if people.contains(where: { Self.fold($0).contains(folded) }) { return true }
        if attendees.contains(where: { Self.fold($0).contains(folded) }) { return true }
        return Self.contains(name, in: everything)
    }

    /// Digits only, so "(555) 123 4567" and "5551234567" are the same number.
    func confirmsNumber(_ number: String) -> Bool {
        let digits = number.filter(\.isNumber)
        // Short runs of digits are dates, quantities and version numbers, not contact
        // details. Treating "3" as an unconfirmed phone number would flag every sentence.
        guard digits.count >= 7 else { return true }
        return everything.digits.contains(digits)
    }

    /// A date is confirmed when *some* surface form of it was actually said: the weekday,
    /// the month and day, the clock time, or the words "today"/"tomorrow" for the day it
    /// resolves to. A literal match alone would flag every well-formed RFC 3339 timestamp
    /// as invented, because nobody speaks in RFC 3339.
    func confirmsDate(_ value: String) -> Bool {
        let haystack = everything
        if Self.contains(value, in: haystack) { return true }
        guard let date = Self.parseDate(value) else {
            // Unparseable and unquoted: it is a string the model made up.
            return false
        }
        // Substring rather than whole-word: a surface form is "1:40" or "sept 9" as often
        // as it is a single word, and neither survives tokenisation.
        for form in Self.surfaceForms(of: date, relativeTo: now) where haystack.text.contains(form) {
            return true
        }
        return false
    }

    /// A file is confirmed when it exists, was named, or its name was said.
    func confirmsFile(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if files.contains(where: { Self.fold($0) == Self.fold(trimmed) }) { return true }
        if trimmed.hasPrefix("/"), FileManager.default.fileExists(atPath: trimmed) { return true }
        let name = URL(fileURLWithPath: trimmed).deletingPathExtension().lastPathComponent
        return !name.isEmpty && Self.contains(name, in: everything)
    }

    // MARK: - Text

    /// NFC first, then diacritic- and case-folded. Without the NFC pass an accented name
    /// coming off the file system never matches the same name coming out of the model.
    static func fold(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Present as a phrase, or present as all of its words — each as a **whole word**.
    ///
    /// The word half is what lets "Marie Dupont" match a transcript that says "Dupont,
    /// Marie". It used to ask whether each word appeared anywhere in the haystack as a bare
    /// substring, which on a real 110 KB transcript confirms almost anything: an invented
    /// attendee "Ana Lee" is confirmed by a transcript containing "analysis" and "asleep",
    /// and the card then prints "You said this." over a name nobody said. So the haystack is
    /// tokenised once and the words are looked up in that set.
    ///
    /// The phrase half stays a substring test, but only for a value that is more than one
    /// word: a multi-word phrase appearing verbatim is a real sighting, while a bare word
    /// is exactly the case above.
    private static func contains(_ value: String, in haystack: ToolCallHaystack) -> Bool {
        let folded = fold(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folded.isEmpty, !haystack.isEmpty else { return false }
        let all = ToolCallHaystack.words(in: folded)
        if all.count > 1, haystack.text.contains(folded) { return true }
        // Short words are initials and particles — "J.", "de", "van" — and dropping them
        // keeps "Marie de Luca" matching a transcript that writes "Marie De Luca". They are
        // only dropped when something longer is left to check.
        let significant = all.filter { $0.count >= 3 }
        let words = significant.isEmpty ? all : significant
        guard !words.isEmpty else { return false }
        return words.allSatisfy { haystack.words.contains($0) }
    }

    // MARK: - Dates

    private static func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// The ways a person might have said this moment out loud.
    private static func surfaceForms(of date: Date, relativeTo now: Date) -> [String] {
        var forms: [String] = []
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)

        let symbols = DateFormatter()
        symbols.locale = Locale(identifier: "en_US_POSIX")
        if let month = components.month, month >= 1, month <= 12 {
            let name = symbols.monthSymbols[month - 1]
            forms.append(fold(name))
            forms.append(fold(symbols.shortMonthSymbols[month - 1]))
        }
        let weekday = calendar.component(.weekday, from: date)
        if weekday >= 1, weekday <= 7 { forms.append(fold(symbols.weekdaySymbols[weekday - 1])) }

        if let day = components.day {
            if let month = components.month, month >= 1, month <= 12 {
                forms.append(fold("\(symbols.monthSymbols[month - 1]) \(day)"))
            }
            forms.append("the \(day)")
        }
        if let hour = components.hour, let minute = components.minute {
            let twelve = hour % 12 == 0 ? 12 : hour % 12
            forms.append(String(format: "%d:%02d", twelve, minute))
            forms.append(String(format: "%d:%02d", hour, minute))
            if minute == 0 {
                forms.append("\(twelve) \(hour < 12 ? "am" : "pm")")
                forms.append("\(twelve)\(hour < 12 ? "am" : "pm")")
                forms.append("\(twelve) o'clock")
            }
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? .max
        switch days {
        case 0: forms.append("today"); forms.append("this afternoon"); forms.append("tonight")
        case 1: forms.append("tomorrow")
        case 2...7: forms.append("next week"); forms.append("this week")
        default: break
        }
        return forms.map(fold).filter { !$0.isEmpty }
    }
}

// MARK: - Folded text, derived once

/// One body of text, folded and tokenised, ready to be asked the same question repeatedly.
///
/// This exists because of where the questions are asked from. A proposal card reads its
/// review while SwiftUI evaluates a body, each review asks four to six grounding questions,
/// and each question used to re-derive the whole haystack: a fresh
/// `precomposedStringWithCanonicalMapping` and ICU fold over the entire transcript. The
/// transcripts on this machine are 110 KB, 70 KB and 38 KB, so one redraw of one card was
/// megabytes of normalisation. Folding is now done once per distinct text and the last few
/// are kept, which is enough for a card that is rebuilt while the user types into it.
///
/// `words` is the other half of the reason: a whole-word lookup needs a set, and building
/// one per question would be worse than the folding it replaced.
final class ToolCallHaystack: Sendable {
    /// NFC-normalised, diacritic- and case-folded.
    let text: String
    /// Every alphanumeric run in `text`, for whole-word questions.
    let words: Set<String>
    /// Every digit in `text`, in order, so a phone number can be looked for without
    /// caring how it was punctuated.
    let digits: String

    var isEmpty: Bool { text.isEmpty }

    private init(raw: String) {
        let folded = ToolCallContext.fold(raw)
        text = folded
        words = Set(Self.words(in: folded))
        digits = String(folded.filter(\.isNumber))
    }

    static func words(in folded: String) -> [String] {
        folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    // MARK: Memo

    /// Small and strictly bounded: a context has three haystacks (what the user said, what
    /// the app can point at, and both together), and at most a couple of contexts are on
    /// screen at once. Anything beyond that is a different meeting, which should be built
    /// fresh rather than held.
    private static let capacity = 8
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [(raw: String, haystack: ToolCallHaystack)] = []

    static func folded(_ raw: String) -> ToolCallHaystack {
        lock.lock()
        if let index = entries.firstIndex(where: { $0.raw == raw }) {
            let hit = entries.remove(at: index)
            entries.append(hit)
            lock.unlock()
            return hit.haystack
        }
        lock.unlock()

        let built = ToolCallHaystack(raw: raw)
        lock.lock()
        entries.append((raw, built))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        lock.unlock()
        return built
    }
}
