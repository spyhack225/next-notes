import Foundation

/// One finished catch-up, as a person sees it.
///
/// Nothing here is stored. A catch-up already exists as the finished run that wrote it: its
/// words are the run's result, its time is when the run finished, and its audio is the file
/// the run's saved-audio step linked to the same record. This type only reads those three
/// and says them in a person's words — it is the shape the Library row, the "ready" card
/// and the closing offer draw, so none of them re-derive a sentence of their own.
struct CatchUpEntry: Identifiable, Equatable {
    /// The run's id. It is the only handle the audio, the offer and the "ready" card share.
    let id: String
    /// "Your morning catch-up", "While you were out" — what the person was shown when it arrived.
    var title: String
    var madeAt: Date
    /// The same words that were delivered, read on screen and spoken in the audio.
    var text: String
    var audioURL: URL?
    var duration: TimeInterval?
    /// Up to four short lines, most urgent first.
    var headlines: [String]
    /// The closing question, if the catch-up ended on one.
    var offer: CatchUpOffer?

    /// How long a catch-up that has no audio yet is still described as "getting the audio
    /// ready". The saved-audio step can wait several minutes for a busy Mac, and nothing
    /// tells the screen it has given up, so the screen stops promising after this.
    static let audioWaitWindow: TimeInterval = 15 * 60

    /// How long the closing question is still worth answering with a button. A question about
    /// "the reminders" is about this morning; offered again tomorrow it is about nothing.
    static let offerLifetime: TimeInterval = 18 * 60 * 60

    func isPreparingAudio(now: Date) -> Bool {
        audioURL == nil && now.timeIntervalSince(madeAt) < Self.audioWaitWindow
    }

    func offerIsFresh(now: Date) -> Bool {
        offer != nil && now.timeIntervalSince(madeAt) < Self.offerLifetime
    }
}

/// The question a catch-up ends on, and the button it becomes.
struct CatchUpOffer: Equatable {
    /// The sentence as written: "Want me to send the reminders?"
    var question: String
    /// The primary button: "Send the reminders", or "Yes, do that" when the question does not
    /// start in a shape we can turn into a verb phrase.
    var actionLabel: String
    /// What saying yes sends the Agent as an ordinary turn. Anything that writes or sends
    /// still stops at the normal approval card, so one press is never an approval to send.
    var yesText: String
}

/// Reading a catch-up's words: its headlines, its closing offer, and how it is dated.
///
/// Pure and deterministic on purpose — no model pass runs on the way to the screen — and
/// every rule below is a reading of what the catch-up's own prompt asks for: short
/// paragraphs, most urgent first, a greeting up front and a question at the end.
enum CatchUpText {
    // MARK: - Building an entry

    /// The entry for a finished catch-up run, or nil when the run has no words to show.
    static func entry(
        id: String, title: String, madeAt: Date, text: String,
        audioURL: URL?, duration: TimeInterval?
    ) -> CatchUpEntry? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return CatchUpEntry(
            id: id, title: title, madeAt: madeAt, text: body, audioURL: audioURL,
            duration: duration, headlines: headlines(from: body), offer: offer(from: body))
    }

    // MARK: - Sentences

    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "jr", "sr", "vs", "etc", "no", "inc", "co",
        "a.m", "p.m", "e.g", "i.e",
    ]

    /// Splits a paragraph into sentences at `. ! ?` followed by a space, without cutting
    /// "Ms. Rivera" or "6 p.m. today" in half.
    static func sentences(of paragraph: String) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(paragraph)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            current.append(character)
            if ".!?".contains(character) {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                let atEnd = next == nil
                let beforeSpace = next.map { $0.isWhitespace } ?? false
                if atEnd || (beforeSpace && !endsWithAbbreviation(current)) {
                    let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sentence.isEmpty { result.append(sentence) }
                    current = ""
                }
            }
            index += 1
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    private static func endsWithAbbreviation(_ text: String) -> Bool {
        guard text.hasSuffix(".") else { return false }
        let word = text.dropLast().split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        return abbreviations.contains(word.lowercased())
    }

    static func paragraphs(of text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Headlines

    /// Longest a headline gets before it is cut at a word and given an ellipsis.
    static let headlineLimit = 72
    static let headlineCount = 4

    private static let greetingOpening = try? NSRegularExpression(
        pattern: "^(good (morning|afternoon|evening)|welcome back|hi|hello|hey|morning)\\b",
        options: [.caseInsensitive])

    private static func isGreeting(_ sentence: String) -> Bool {
        guard sentence.split(separator: " ").count <= 8,
              let regex = greetingOpening else { return false }
        let range = NSRange(sentence.startIndex..., in: sentence)
        return regex.firstMatch(in: sentence, range: range) != nil
    }

    /// The first sentence of each paragraph, most urgent first, with the greeting and the
    /// closing question left out. The prompt writes one thought per paragraph in order of
    /// what needs the person, so the opening line of each is the thing that paragraph is about.
    static func headlines(from text: String) -> [String] {
        let question = offer(from: text)?.question
        var lines: [String] = []
        for paragraph in paragraphs(of: text) {
            let candidates = sentences(of: paragraph).filter { $0 != question && !isGreeting($0) }
            guard let first = candidates.first else { continue }
            lines.append(shortened(first))
            if lines.count == headlineCount { break }
        }
        return lines
    }

    static func shortened(_ sentence: String, limit: Int = headlineLimit) -> String {
        var line = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = line.last, ".!".contains(last) { line.removeLast() }
        guard line.count > limit else { return line }
        let head = String(line.prefix(limit))
        let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-")) + "\u{2026}"
    }

    // MARK: - The closing offer

    private static let askOpenings = [
        "do you want me to ", "would you like me to ", "want me to ", "shall i ", "should i ",
        "can i ", "may i ", "do you want to ", "would you like to ", "want to ",
    ]

    /// The closing question as a button, or nil when the catch-up does not end on one.
    static func offer(from text: String) -> CatchUpOffer? {
        guard let paragraph = paragraphs(of: text).last,
              let last = sentences(of: paragraph).last, last.hasSuffix("?") else { return nil }
        let lowered = last.lowercased()
        var phrase: String?
        for opening in askOpenings where lowered.hasPrefix(opening) {
            var rest = String(last.dropFirst(opening.count))
            rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "? .,"))
            phrase = rest
            break
        }
        // A verb phrase that is about "you" or "I" would read as a riddle on a button.
        if let rest = phrase, !rest.isEmpty, rest.count <= 44,
           !["you ", "your ", "i ", "me "].contains(where: { rest.lowercased().hasPrefix($0) }) {
            let label = rest.prefix(1).uppercased() + rest.dropFirst()
            return CatchUpOffer(
                question: last, actionLabel: label, yesText: "Yes, go ahead and \(rest).")
        }
        return CatchUpOffer(
            question: last, actionLabel: "Yes, do that",
            yesText: "Yes, please. You asked: \u{201C}\(last)\u{201D}")
    }

    // MARK: - How a catch-up is dated and measured

    /// "This morning, 7:02 AM", "Yesterday, 6:00 AM", "Monday, 7:02 AM", "Oct 5, 7:02 AM".
    static func whenPhrase(
        _ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let time = date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                             calendar: calendar, timeZone: calendar.timeZone))
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        let lead: String
        switch days {
        case ..<0:
            lead = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar,
                                                   timeZone: calendar.timeZone)
                .month(.abbreviated).day())
        case 0:
            let hour = calendar.component(.hour, from: date)
            lead = hour < 12 ? "This morning" : hour < 17 ? "This afternoon" : "This evening"
        case 1:
            lead = "Yesterday"
        case 2...6:
            lead = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar,
                                                   timeZone: calendar.timeZone).weekday(.wide))
        default:
            lead = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar,
                                                   timeZone: calendar.timeZone)
                .month(.abbreviated).day())
        }
        return "\(lead), \(time)"
    }

    /// "Under a minute", "2 min".
    static func lengthPhrase(_ seconds: TimeInterval) -> String {
        guard seconds >= 45 else { return "Under a minute" }
        return "\(max(1, Int((seconds / 60).rounded()))) min"
    }

    /// "0:07".
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
