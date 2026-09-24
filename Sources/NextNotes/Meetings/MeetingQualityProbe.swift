import Foundation

/// Deterministic transcript-quality probe for meetings (M-16a).
///
/// Nothing here transcribes, diarizes or writes notes. It classifies the
/// language of each transcript line from stop-word markers and summarises a
/// finished meeting's transcript into one `MeetingQuality` value, so every
/// later meeting task (M-01, M-03, M-04, M-05) can state its improvement as a
/// before/after number rather than a hunch. Pure: no store, no model.
enum TranscriptLanguageProbe {
    enum Guess: String, Sendable { case english, french, unknown }

    /// Lowercase, fold ’ to ', split on anything that is not a letter or an
    /// apostrophe, count tokens in `englishMarkers` and `frenchMarkers`.
    /// english: en ≥ 2 && en > fr.  french: fr ≥ 2 && fr > en.  otherwise unknown.
    static func guess(_ text: String) -> Guess {
        let folded = text.lowercased().replacingOccurrences(of: "’", with: "'")
        var english = 0
        var french = 0
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            if englishMarkers.contains(current) { english += 1 }
            if frenchMarkers.contains(current) { french += 1 }
            current = ""
        }
        for scalar in folded.unicodeScalars {
            if CharacterSet.letters.contains(scalar) || scalar == "'" {
                current.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        if english >= 2 && english > french { return .english }
        if french >= 2 && french > english { return .french }
        return .unknown
    }

    static let englishMarkers: Set<String> = [
        "the", "and", "is", "are", "it", "it's", "you", "to", "of", "that",
        "this", "with", "for", "have", "so", "like", "what", "can", "if",
        "don't", "was", "be", "we", "they", "there", "just", "about",
        "would", "going", "i'm",
    ]
    static let frenchMarkers: Set<String> = [
        "le", "la", "les", "et", "est", "de", "des", "du", "que", "qui",
        "un", "une", "je", "tu", "il", "elle", "pas", "ça", "pour", "avec",
        "dans", "mais", "c'est", "nous", "vous", "sur", "au", "aux", "très",
        "donc", "alors", "j'ai", "n'est",
    ]
}

struct MeetingQuality: Sendable, Equatable {
    var segments: Int
    var maxSegmentSeconds: Double
    var shortSegmentShare: Double
    var dominantLanguage: TranscriptLanguageProbe.Guess
    var guessedSegments: Int
    var wrongLanguageSegments: Int
    var wrongLanguageShare: Double
    var systemSegments: Int
    var unattributedSystemShare: Double?
    var speakerLabels: Int
    var distinctNames: Int
    var overSplit: Bool { speakerLabels > distinctNames }
}

enum MeetingQualityProbe {
    static func measure(meeting: Meeting, segments: [TranscriptSegment]) -> MeetingQuality {
        // Agent commands stay in the audit trail and out of every number here.
        let lines = segments.filter { $0.kind != .agentCommand }
        let guesses = lines.map { TranscriptLanguageProbe.guess($0.text) }
        let english = guesses.filter { $0 == .english }.count
        let french = guesses.filter { $0 == .french }.count
        let guessed = english + french
        let dominant: TranscriptLanguageProbe.Guess
        if english > french {
            dominant = .english
        } else if french > english {
            dominant = .french
        } else {
            dominant = .unknown
        }
        // With no dominant language there is no "wrong" language either: a tie
        // or an all-unknown transcript reports share 0.
        let wrong: Int
        let wrongShare: Double
        if dominant == .unknown || guessed == 0 {
            wrong = 0
            wrongShare = 0
        } else {
            wrong = zip(lines, guesses).filter { _, guess in
                guess != .unknown && guess != dominant
            }.count
            wrongShare = Double(wrong) / Double(guessed)
        }
        let durations = lines.map { max(0, $0.end - $0.start) }
        let short = durations.filter { $0 < 1.0 }.count
        let system = lines.filter { $0.source == .system }
        let labelled = system.filter { $0.speaker != nil }
        // Nil while nothing on the system track carries a speaker: the meeting
        // has not been diarized, so "unattributed" has no meaning yet.
        let unattributed: Double? = labelled.isEmpty
            ? nil
            : Double(system.count - labelled.count) / Double(system.count)
        let labels = Set(system.compactMap(\.speaker))
        let names = Set(labels.map { meeting.speakerNames[$0] ?? $0 })
        return MeetingQuality(
            segments: lines.count,
            maxSegmentSeconds: durations.max() ?? 0,
            shortSegmentShare: lines.isEmpty ? 0 : Double(short) / Double(lines.count),
            dominantLanguage: dominant,
            guessedSegments: guessed,
            wrongLanguageSegments: wrong,
            wrongLanguageShare: wrongShare,
            systemSegments: system.count,
            unattributedSystemShare: unattributed,
            speakerLabels: labels.count,
            distinctNames: names.count
        )
    }

    static func line(for meeting: Meeting, quality: MeetingQuality) -> String {
        let day = Self.dayFormatter.string(from: meeting.start)
        let minutes = Int((meeting.duration ?? 0) / 60)
        let lang: String
        switch quality.dominantLanguage {
        case .english: lang = "en"
        case .french: lang = "fr"
        case .unknown: lang = "?"
        }
        let short = Int((quality.shortSegmentShare * 100).rounded())
        let wrong = Int((quality.wrongLanguageShare * 100).rounded())
        let unlabelled: String
        if let share = quality.unattributedSystemShare {
            unlabelled = "\(Int((share * 100).rounded()))%"
        } else {
            unlabelled = "n/a"
        }
        return """
            MEETING_QUALITY \(meeting.id.uuidString.prefix(4)) \(day) \
            \(minutes)min segs=\(quality.segments) \
            max=\(String(format: "%.1f", quality.maxSegmentSeconds))s \
            short=\(short)% lang=\(lang) wrong=\(wrong)% \
            (\(quality.wrongLanguageSegments)/\(quality.guessedSegments)) \
            sys=\(quality.systemSegments) unlabelled=\(unlabelled) \
            labels=\(quality.speakerLabels) names=\(quality.distinctNames)
            """
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// In-memory cases only: no store, no `runs.jsonl`, no `UserDefaults`.
    static func runSelfTest() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            if !condition() { failures.append(name) }
        }

        // a. I2's four wrong-language samples must read as English.
        let englishSamples = [
            "So if you don't have to pass it, you can be very and I use it to be two AC sounds like",
            "Uh it's a good time as a parking lot of it.",
            "Like on that on that C the power of the one parentheses the most the poem and a one DP.",
            "Bueno, it would be this way.",
        ]
        for sample in englishSamples {
            check(
                "english sample guessed \(TranscriptLanguageProbe.guess(sample)) (want english): \(sample)",
                TranscriptLanguageProbe.guess(sample) == .english
            )
        }

        // b. French lines read as French; fragments too short to judge stay unknown.
        let frenchSamples = [
            "Donc on garde le budget à quarante mille pour le moment.",
            "Oui c'est ça, je t'envoie le devis demain.",
            "Il faut que Marc valide avec la banque.",
            "Non mais attends, ce n'est pas le même prix.",
        ]
        for sample in frenchSamples {
            check(
                "french sample guessed \(TranscriptLanguageProbe.guess(sample)) (want french): \(sample)",
                TranscriptLanguageProbe.guess(sample) == .french
            )
        }
        check("OK. guessed, want unknown", TranscriptLanguageProbe.guess("OK.") == .unknown)
        check("Merci. guessed, want unknown", TranscriptLanguageProbe.guess("Merci.") == .unknown)

        // c. A 20-segment French transcript with 3 English lines and 2 unknowns.
        var frenchLines: [TranscriptSegment] = []
        for i in 0..<15 {
            frenchLines.append(TranscriptSegment(
                start: Double(i) * 3, end: Double(i) * 3 + 2.5,
                text: "Donc on garde le budget à quarante mille pour le moment, et Marc valide.",
                source: .system
            ))
        }
        for i in 15..<18 {
            frenchLines.append(TranscriptSegment(
                start: Double(i) * 3, end: Double(i) * 3 + 2.5,
                text: "So if you don't have to pass it, you can be there with us.",
                source: .system
            ))
        }
        for i in 18..<20 {
            frenchLines.append(TranscriptSegment(
                start: Double(i) * 3, end: Double(i) * 3 + 2.5,
                text: "OK.",
                source: .system
            ))
        }
        let frenchMeeting = Meeting(title: "fr", start: Date(), end: Date(), status: .done)
        let frenchQuality = measure(meeting: frenchMeeting, segments: frenchLines)
        check("dominant is \(frenchQuality.dominantLanguage), want french",
              frenchQuality.dominantLanguage == .french)
        check("guessed is \(frenchQuality.guessedSegments), want 18",
              frenchQuality.guessedSegments == 18)
        check("wrong is \(frenchQuality.wrongLanguageSegments), want 3",
              frenchQuality.wrongLanguageSegments == 3)
        check("share is \(frenchQuality.wrongLanguageShare), want 3/18",
              abs(frenchQuality.wrongLanguageShare - 3.0 / 18.0) < 1e-9)

        // d. Attribution and over-split on the system track.
        var labelled: [TranscriptSegment] = []
        for i in 0..<3 {
            labelled.append(TranscriptSegment(
                start: Double(i), end: Double(i) + 1, text: "Oui c'est ça.",
                source: .system, speaker: nil
            ))
        }
        for i in 3..<7 {
            labelled.append(TranscriptSegment(
                start: Double(i), end: Double(i) + 1, text: "Oui c'est ça.",
                source: .system, speaker: "Speaker 1"
            ))
        }
        for i in 7..<10 {
            labelled.append(TranscriptSegment(
                start: Double(i), end: Double(i) + 1, text: "Oui c'est ça.",
                source: .system, speaker: "Speaker 2"
            ))
        }
        var merged = Meeting(title: "sys", start: Date(), end: Date(), status: .done)
        merged.speakerNames = ["Speaker 1": "Papa", "Speaker 2": "Papa"]
        let labelledQuality = measure(meeting: merged, segments: labelled)
        check("unattributed is \(String(describing: labelledQuality.unattributedSystemShare)), want 0.3",
              labelledQuality.unattributedSystemShare == 0.3)
        check("labels is \(labelledQuality.speakerLabels), want 2",
              labelledQuality.speakerLabels == 2)
        check("names is \(labelledQuality.distinctNames), want 1",
              labelledQuality.distinctNames == 1)
        check("overSplit is \(labelledQuality.overSplit), want true",
              labelledQuality.overSplit == true)
        let bare = measure(
            meeting: Meeting(title: "bare", start: Date(), end: Date(), status: .done),
            segments: (0..<3).map {
                TranscriptSegment(start: Double($0), end: Double($0) + 1,
                                  text: "Oui c'est ça.", source: .system, speaker: nil)
            }
        )
        check("undiarized unattributed is \(String(describing: bare.unattributedSystemShare)), want nil",
              bare.unattributedSystemShare == nil)

        // e. Segment lengths 0.5, 0.9, 1.0, 3.0 s. All start at 0 so the
        // durations are exact literals rather than accumulated floats.
        let lengths = [0.5, 0.9, 1.0, 3.0]
        let sized = lengths.map { length in
            TranscriptSegment(
                start: 0, end: length,
                text: "Okay so the plan is to ship it.", source: .mic
            )
        }
        let sizedQuality = measure(
            meeting: Meeting(title: "sizes", start: Date(), end: Date(), status: .done),
            segments: sized
        )
        check("short share is \(sizedQuality.shortSegmentShare), want 0.5",
              sizedQuality.shortSegmentShare == 0.5)
        check("max is \(sizedQuality.maxSegmentSeconds), want 3.0",
              sizedQuality.maxSegmentSeconds == 3.0)

        return failures
    }
}
