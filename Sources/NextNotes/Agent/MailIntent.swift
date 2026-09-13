import Foundation

/// What a spoken or typed mail request is asking for. Same shape as `ComputerIntent`
/// and `CalendarIntent`: parse first, run the tool.
enum MailIntent: Equatable {
    case search(query: String)

    var query: String {
        switch self {
        case .search(let query): query
        }
    }

    static func parse(_ raw: String) -> MailIntent? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lowered = text.lowercased()
        guard mentionsMail(lowered), !isCompose(lowered) else { return nil }
        return .search(query: searchQuery(from: lowered))
    }

    /// Gmail search syntax. Unread when they asked about missing mail; otherwise the
    /// last two days of the inbox, which is what “what’s happening on my email” means.
    static func searchQuery(from lowered: String) -> String {
        if unreadMarks.contains(where: { lowered.contains($0) }) {
            return "is:unread"
        }
        return "in:inbox newer_than:2d"
    }

    private static func mentionsMail(_ lowered: String) -> Bool {
        if mailNouns.contains(where: { lowered.contains($0) }) { return true }
        return checkMarks.contains(where: { lowered.contains($0) })
            && mailWords.contains(where: { lowered.contains($0) })
    }

    private static func isCompose(_ lowered: String) -> Bool {
        composeMarks.contains { lowered.contains($0) }
    }

    private static let mailNouns = [
        "inbox", "gmail", "my email", "my mail", "the email",
        "any email", "any emails", "emails", "e-mail",
    ]

    private static let mailWords = ["email", "e-mail", "gmail", "inbox", "mail"]

    private static let checkMarks = [
        "check", "checking", "search", "look", "read", "unread", "missed",
        "what's happening", "whats happening", "what is happening",
        "what's in", "whats in",
    ]

    private static let unreadMarks = [
        "unread", "missed", "new email", "new emails", "any email", "any emails",
        "didn't miss", "did not miss", "haven't read", "have not read",
    ]

    private static let composeMarks = [
        "send an email", "send email", "draft an email", "draft email",
        "compose", "write an email", "write email",
        "email the", "email him", "email her", "email them",
    ]
}
