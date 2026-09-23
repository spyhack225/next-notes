import Foundation

/// P1-6: one action a read result makes obvious, offered as a single button.
///
/// The strict rule from the roadmap: only actions whose arguments are **fully determined
/// by the result the user just saw**. A URL the result printed verbatim is determined; a
/// date or a recipient the app would have to infer is not, and stays a sentence the user
/// can say. That is the same line `FunctionCallRelevance` draws around the catalogue, and
/// it is why this builder has exactly two shapes: open the one page, or open the one file.
///
/// An offer is never executed on the user's behalf. Pressing the button submits an
/// ordinary task, which goes through `PermissionBroker` like anything else; the button is
/// the sentence the user would otherwise have had to type.
struct FollowUpOffer: Identifiable, Equatable, Sendable {
    let id: String
    /// The button's words. A verb and its object: "Open it".
    let title: String
    /// The one line above the button, saying what pressing it would do.
    let sentence: String
    /// The tool the button would run.
    let toolID: String
    /// Every argument, taken from the result itself.
    let arguments: [String: String]
}

enum FollowUpOfferBuilder {
    /// The single next action this result determines, or nil.
    ///
    /// Nil is the ordinary answer, and the reason this is a builder rather than a rule in
    /// a view: a read that names two pages, or a page it did not print, offers nothing.
    static func offer(for toolID: String, result: String) -> FollowUpOffer? {
        guard readToolIDs.contains(toolID) else { return nil }
        if let url = singlePage(in: result) {
            return FollowUpOffer(
                id: "open-page",
                title: "Open it",
                sentence: "Want me to open \(url.host ?? "the page") for you?",
                toolID: "computer.open_url",
                arguments: ["url": url.absoluteString]
            )
        }
        return nil
    }

    /// Read-class tools whose results are lists of things the user asked to find. A write
    /// or a send never offers a follow-up: its card is the approval, not a shortcut past it.
    static let readToolIDs: Set<String> = [
        "search_email", "workspace.search_email",
        "get_agenda", "workspace.get_agenda",
        "find_drive_files", "workspace.find_drive_files",
        "read_doc", "workspace.read_doc",
        "filesystem.search",
        "search_knowledge",
    ]

    /// The one http(s) page in the result, or nil when there is none or more than one.
    ///
    /// More than one is deliberately nil: "open it" with two candidates is a question, and
    /// a button cannot ask one.
    static func singlePage(in result: String) -> URL? {
        let pattern = #"https?://[^\s<>"'\)\]]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(result.startIndex..., in: result)
        let matches = regex.matches(in: result, range: range)
        guard matches.count == 1, let match = matches.first,
              let swiftRange = Range(match.range, in: result)
        else { return nil }
        let raw = String(result[swiftRange]).trimmingCharacters(
            in: CharacterSet(charactersIn: ".,;:")
        )
        guard let url = URL(string: raw), url.scheme == "http" || url.scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }
}
