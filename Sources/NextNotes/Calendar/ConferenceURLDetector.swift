import Foundation

/// Finds the "join the call" link in whatever a calendar entry happens to carry.
///
/// Which field holds it depends entirely on who created the invitation: Google puts it in
/// `hangoutLink` and in the description, Zoom's plugin puts it in the location, Teams
/// buries it in a block of HTML in the notes. Rather than special-casing each, every field
/// is scanned in the order most likely to hold the real link and the first known
/// conferencing host wins.
enum ConferenceURLDetector {

    /// Hosts that mean "this is a video call". Matched as suffixes, so `us02web.zoom.us`
    /// and `acme.webex.com` are both recognised without listing every tenant.
    static let hosts = [
        "zoom.us",
        "meet.google.com",
        "teams.microsoft.com",
        "teams.live.com",
        "webex.com",
        "whereby.com",
        "around.co",
    ]

    /// Scans the given fields in order and returns the first conference link found.
    static func detect(in fields: [String?]) -> URL? {
        for field in fields {
            guard let field, !field.isEmpty else { continue }
            if let url = firstConferenceURL(in: field) { return url }
        }
        return nil
    }

    /// A URL is a conference link when its host ends in one of `hosts`.
    static func isConference(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private static func firstConferenceURL(in text: String) -> URL? {
        // Trailing punctuation is excluded from the match rather than trimmed afterwards:
        // a link at the end of a sentence in a description otherwise keeps its full stop,
        // and Zoom's own links legitimately end in digits and `?pwd=` query strings.
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in Self.linkPattern.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let candidate = String(text[matchRange])
            guard let url = URL(string: candidate), isConference(url) else { continue }
            return url
        }
        return nil
    }

    /// Compiled once: this runs over every event of every refresh.
    ///
    /// Force-unwrapped on purpose — the pattern is a literal in this file, so a failure
    /// here is a typo caught by the first test run, not a runtime condition.
    private static let linkPattern = try! NSRegularExpression(
        pattern: "https?://[A-Za-z0-9._~:/?#\\[\\]@!$&'()*+,;=%-]+[A-Za-z0-9/=]"
    )
}
