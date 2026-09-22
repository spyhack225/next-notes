import Foundation

/// The three requests that do not need a 4B planner, and what they cost when they get one.
///
/// 2026-09-20T20:45:00Z, from `metrics.jsonl`: "You open Google Chrome and go to
/// youtube.com." The frontend said "I'm on it." in 0.38 s, then the background worker built
/// the planner prompt — persona, rules, memory, today's date, the file-index sentence, the
/// skills index and the full schema of fifty-odd tools — and Qwen3.5-4B spent **44.78 s**
/// prefilling 3,634 tokens before its first token. The spoken result landed 47 s after the
/// request. The second request queued behind it and waited another 3.76 s to start.
///
/// Prefill is the whole bill, and it is paid per round. "Open Chrome and go to youtube.com"
/// needs no plan: it is two calls whose arguments are in the sentence. Parsing them here
/// costs microseconds and skips the model entirely. Everything else still goes to the
/// planner — this is a shortcut, never a gate.
///
/// The approval boundary is untouched: each action still goes through
/// `AgentToolExecutor.run`, which shows the exact URL, app or path and waits for the user.
enum AgentDirectIntent: Equatable, Sendable {
    /// A page, optionally in a named browser.
    case openURL(url: String, app: String?)
    /// An application by name.
    case openApp(String)
    /// A file or folder the user named out loud, to be found in the index and revealed.
    case locate(query: String, wantsFolder: Bool)

    /// The tool ids this intent needs. The caller refuses the shortcut when any is missing
    /// from the planner's allow-list, so the fast path can never reach past it.
    var requiredToolIDs: [String] {
        switch self {
        case .openURL(_, let app):
            app == nil ? ["browser.navigate"] : ["computer.open_app", "browser.navigate"]
        case .openApp: ["computer.open_app"]
        case .locate: [FileToolCatalogue.findID, "filesystem.reveal"]
        }
    }

    /// What is said while the action runs — truthful, and specific enough to be worth hearing.
    var progressTitle: String {
        switch self {
        case .openURL(let url, _): "Opening \(url)…"
        case .openApp(let name): "Opening \(name)…"
        case .locate(let query, _): "Looking for \(query)…"
        }
    }

    // MARK: - Parsing

    /// Words that carry no meaning at the front of a dictated request. "nothing" is here
    /// because the recogniser emits it for a false start — the 20:45:41 turn began
    /// "can you also nothing get to my folder…".
    private static let leadingFiller: Set<String> = [
        "hey", "hi", "ok", "okay", "so", "um", "uh", "er", "well", "please", "just", "now",
        "also", "and", "then", "can", "could", "would", "will", "you", "your", "do", "i",
        "want", "need", "like", "to", "me", "my", "nothing", "next", "will's", "let's",
    ]

    /// Site words a person says without a domain. Each maps to the page they mean.
    private static let knownSites: [String: String] = [
        "youtube": "https://www.youtube.com", "gmail": "https://mail.google.com",
        "google": "https://www.google.com", "github": "https://github.com",
        "linkedin": "https://www.linkedin.com", "reddit": "https://www.reddit.com",
        "wikipedia": "https://www.wikipedia.org", "amazon": "https://www.amazon.com",
        "netflix": "https://www.netflix.com", "spotify": "https://open.spotify.com",
        "chatgpt": "https://chatgpt.com", "notion": "https://www.notion.so",
        "twitter": "https://x.com", "drive": "https://drive.google.com",
    ]

    /// Browsers and the few apps worth recognising by ear. An unrecognised app name is not
    /// guessed: that request goes to the planner, which can inspect what is installed.
    private static let knownApps: [String: String] = [
        "chrome": "Google Chrome", "google chrome": "Google Chrome", "safari": "Safari",
        "firefox": "Firefox", "arc": "Arc", "edge": "Microsoft Edge",
        "finder": "Finder", "mail": "Mail", "messages": "Messages", "notes": "Notes",
        "calendar": "Calendar", "terminal": "Terminal", "xcode": "Xcode",
        "slack": "Slack", "spotify": "Spotify", "zoom": "zoom.us", "cursor": "Cursor",
    ]

    private static let locateVerbs = [
        "open", "find", "show", "reveal", "go to", "get to", "look for", "locate", "bring up",
    ]

    /// Nil whenever the sentence is not plainly one of the three. A miss costs a planner
    /// round; a false positive costs the user an action they did not ask for, so every rule
    /// below needs an explicit verb and an explicit object.
    static func parse(_ utterance: String) -> AgentDirectIntent? {
        let text = normalize(utterance)
        guard !text.isEmpty else { return nil }
        guard startsWithActionVerb(text) else { return nil }
        if let file = parseLocate(text) { return file }
        return parseOpen(text)
    }

    /// Lowercased, de-punctuated, with wake words and false starts trimmed off the front.
    static func normalize(_ utterance: String) -> String {
        var text = utterance.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "\u{2014}", with: " ")
        text = String(text.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "/" || $0 == ":"
            || $0 == "-" || $0 == "'" || $0 == "_" ? $0 : " " })
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        // Trim filler only while it cannot be the object of the sentence.
        while let first = words.first, leadingFiller.contains(first), words.count > 1 {
            // "open next notes" — the object may share a word with the filler list.
            if locateVerbs.contains(where: { $0.hasPrefix(first) }) { break }
            words.removeFirst()
        }
        return words.joined(separator: " ")
    }

    private static func startsWithActionVerb(_ text: String) -> Bool {
        locateVerbs.contains { text == $0 || text.hasPrefix($0 + " ") }
            || ["launch", "start", "navigate to", "take me to"].contains {
                text == $0 || text.hasPrefix($0 + " ")
            }
    }

    // MARK: - Apps and pages

    private static func parseOpen(_ text: String) -> AgentDirectIntent? {
        let app = namedApp(in: text)
        if let url = namedURL(in: text) { return .openURL(url: url, app: app) }
        guard let app else { return nil }
        // "open chrome" with nothing else in the sentence beyond filler.
        let structural: Set<String> = ["launch", "start", "app", "the", "a", "on", "in", "with", "up"]
        let remainder = text
            .replacingOccurrences(of: spokenAppPhrase(for: app, in: text) ?? "", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !leadingFiller.contains($0) && !locateVerbs.contains($0)
                && !structural.contains($0) }
        guard remainder.isEmpty else { return nil }
        return .openApp(app)
    }

    /// A spelled domain, or a site word the user said on its own.
    static func namedURL(in text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        for word in words {
            let cleaned = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
            if cleaned.hasPrefix("http://") || cleaned.hasPrefix("https://") { return cleaned }
            guard cleaned.contains("."), !cleaned.hasPrefix("."), !cleaned.hasSuffix(".") else { continue }
            let host = cleaned.split(separator: "/").first.map(String.init) ?? cleaned
            guard let suffix = host.split(separator: ".").last, suffix.count >= 2,
                  suffix.allSatisfy(\.isLetter) else { continue }
            return "https://" + cleaned
        }
        // A bare site word only counts when it is not also the app the user named.
        for word in words {
            if let site = knownSites[word], knownApps[word] == nil || words.count > 2 { return site }
        }
        return nil
    }

    /// The app the user named, canonicalised to the name `computer.open_app` expects.
    static func namedApp(in text: String) -> String? {
        // Two-word names first, so "google chrome" is not read as "google".
        for (spoken, app) in knownApps where spoken.contains(" ") {
            if text.contains(spoken) { return app }
        }
        let words = Set(text.split(whereSeparator: \.isWhitespace).map(String.init))
        for (spoken, app) in knownApps where !spoken.contains(" ") {
            // "open google chrome" already matched above; a lone "google" is the site.
            if words.contains(spoken), !(spoken == "google" || spoken == "mail" || spoken == "notes") {
                return app
            }
        }
        return nil
    }

    private static func spokenAppPhrase(for app: String, in text: String) -> String? {
        knownApps.first { $0.value == app && text.contains($0.key) }?.key
    }

    // MARK: - Files and folders

    private static let fileWords: Set<String> = [
        "folder", "folders", "directory", "file", "files", "document", "documents",
        "desktop", "downloads", "project", "projects", "repo", "repository",
    ]

    private static let locateNoise: Set<String> = [
        "my", "the", "a", "an", "in", "on", "to", "into", "at", "of", "for", "called",
        "named", "open", "get", "go", "find", "show", "reveal", "locate", "me", "up",
        "please", "also", "can", "you", "and", "that", "this", "is", "it", "s",
        "folder", "folders", "directory", "file", "files",
    ]

    private static func parseLocate(_ text: String) -> AgentDirectIntent? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.contains(where: { fileWords.contains($0) }) else { return nil }
        let wantsFolder = words.contains { ["folder", "folders", "directory"].contains($0) }
            || words.contains("project") || words.contains("projects")
        let query = locateQuery(words)
        guard !query.isEmpty else { return nil }
        return .locate(query: query, wantsFolder: wantsFolder)
    }

    /// The name inside the sentence.
    ///
    /// "can you also nothing get to my folder to my document folder in open next project"
    /// is what the recogniser produced for one request on 2026-09-20. The name is the tail
    /// after the last naming word — `called`, `named`, or the last `open` — and everything
    /// structural is dropped from it. That leaves "next project", which is not a folder on
    /// this Mac and is not supposed to be: `AgentEntityResolver` matches it by sound.
    static func locateQuery(_ words: [String]) -> String {
        var tail = words
        for marker in ["called", "named", "open"] {
            if let index = words.lastIndex(of: marker), index + 1 < words.count {
                tail = Array(words[(index + 1)...])
                break
            }
        }
        let kept = tail.filter { !locateNoise.contains($0) }
        // "open my documents folder" names a folder with a noise word; keep it rather than
        // returning nothing.
        if kept.isEmpty {
            let fallback = tail.filter { fileWords.contains($0) && $0 != "folder" && $0 != "file" }
            return fallback.joined(separator: " ")
        }
        return kept.joined(separator: " ")
    }
}
