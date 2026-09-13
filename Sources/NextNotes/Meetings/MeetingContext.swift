import Foundation

/// One commitment, question or file mention extracted from the transcript.
struct MeetingContextItem: Sendable, Equatable, Codable, Identifiable {
    var id: String
    var text: String
    var speaker: String?
    var source: AudioSource
    var confidence: String
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        text: String,
        speaker: String? = nil,
        source: AudioSource,
        confidence: String = "medium",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.speaker = speaker
        self.source = source
        self.confidence = confidence
        self.createdAt = createdAt
    }

    /// System audio may propose; it may never authorise.
    var isAuthoritative: Bool { source == .mic }
}

/// A follow-up another participant asked for. Stored, never executed, until the user
/// says to do it.
struct MeetingCandidateAction: Sendable, Equatable, Codable, Identifiable {
    var id: String
    var recipient: String?
    var action: String
    var object: String?
    var speaker: String?
    var source: AudioSource
    var confidence: String
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        recipient: String? = nil,
        action: String,
        object: String? = nil,
        speaker: String? = nil,
        source: AudioSource,
        confidence: String = "medium",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.recipient = recipient
        self.action = action
        self.object = object
        self.speaker = speaker
        self.source = source
        self.confidence = confidence
        self.createdAt = createdAt
    }
}

/// Continuously updated meeting state. The realtime agent reads this instead of an hour of
/// transcript.
struct MeetingContext: Sendable, Equatable, Codable {
    var meetingID: UUID
    var title: String
    var participants: [String]
    var topics: [MeetingContextItem]
    var decisions: [MeetingContextItem]
    var questions: [MeetingContextItem]
    var commitments: [MeetingContextItem]
    var deadlines: [MeetingContextItem]
    var documentsMentioned: [MeetingContextItem]
    var actionItems: [MeetingContextItem]
    var unresolvedItems: [MeetingContextItem]
    var candidateActions: [MeetingCandidateAction]
    var updatedAt: Date

    var overview: String {
        var lines = ["Meeting: \(title)"]
        if !participants.isEmpty {
            lines.append("Participants: \(participants.joined(separator: ", "))")
        }
        lines.append("Updated \(updatedAt.formatted(date: .omitted, time: .shortened)).")
        return lines.joined(separator: "\n")
    }

    var summary: String {
        func block(_ title: String, _ items: [MeetingContextItem]) -> String? {
            guard !items.isEmpty else { return nil }
            return "\(title):\n" + items.map { "- \($0.text)" }.joined(separator: "\n")
        }
        let parts = [
            overview,
            block("Topics", topics),
            block("Decisions", decisions),
            block("Action items", actionItems),
            block("Commitments", commitments),
            block("Questions", questions),
            block("Deadlines", deadlines),
            block("Documents", documentsMentioned),
            block("Unresolved", unresolvedItems),
            candidateActions.isEmpty
                ? nil
                : "Candidate actions (not authorised):\n"
                    + candidateActions.map { "- \($0.action) \($0.object ?? "") \($0.recipient.map { "→ \($0)" } ?? "")" }
                    .joined(separator: "\n"),
        ].compactMap { $0 }
        return parts.joined(separator: "\n\n")
    }

    var actionItemsSummary: String {
        if actionItems.isEmpty && candidateActions.isEmpty {
            return "No action items yet."
        }
        var lines = actionItems.map { "- \($0.text)" }
        for candidate in candidateActions {
            lines.append("- (candidate, \(candidate.source == .system ? "others asked" : "you said")) \(candidate.action) \(candidate.object ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    var decisionsSummary: String {
        decisions.isEmpty
            ? "No decisions recorded."
            : decisions.map { "- \($0.text)" }.joined(separator: "\n")
    }

    static func empty(meetingID: UUID, title: String, participants: [String]) -> MeetingContext {
        MeetingContext(
            meetingID: meetingID,
            title: title,
            participants: participants,
            topics: [],
            decisions: [],
            questions: [],
            commitments: [],
            deadlines: [],
            documentsMentioned: [],
            actionItems: [],
            unresolvedItems: [],
            candidateActions: [],
            updatedAt: Date()
        )
    }
}
