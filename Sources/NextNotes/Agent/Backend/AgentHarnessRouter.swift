import Foundation
import Observation

/// Which execution harness a turn should use. Settings is only the default when history
/// is empty — an explicit name in the utterance always wins.
enum AgentHarnessID: String, Codable, Sendable, CaseIterable {
    case local
    case claude
    case codex
    case qwen
    case opencode

    var backend: AgentBackendKind { self == .local ? .local : .acp }

    var acpCLI: String {
        switch self {
        case .local: ""
        case .claude: "claude"
        case .codex: "codex"
        case .qwen: "qwen"
        case .opencode: "opencode"
        }
    }

    var displayName: String {
        switch self {
        case .local: "local tools"
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .qwen: "Qwen Code"
        case .opencode: "OpenCode"
        }
    }

    var usingLine: String {
        self == .local ? "Using local tools" : "Using \(displayName)"
    }
}

enum AgentIntentClass: String, Codable, Sendable {
    case stayLocal
    case coding
    case general
}

enum AgentHarnessSource: String, Codable, Sendable {
    case explicit
    case history
    case session
    case settings
}

struct AgentHarnessChoice: Equatable, Sendable {
    var id: AgentHarnessID
    var source: AgentHarnessSource
    var available: Bool
    var fallbackToLocal: Bool
    var note: String

    var backend: AgentBackendKind { fallbackToLocal ? .local : id.backend }
    var acpCLI: String { fallbackToLocal ? "" : id.acpCLI }
    var usingLine: String { fallbackToLocal ? AgentHarnessID.local.usingLine : id.usingLine }
}

struct AgentHarnessMemory: Codable, Sendable, Equatable {
    var snippet: String
    var intentClass: String
    var harnessID: String
    var at: Date
}

/// Picks Local vs an ACP coding CLI per request. Calendar, mail, Drive, Docs and
/// click/type stay local unless the user named a harness.
@MainActor
@Observable
final class AgentHarnessRouter {
    static let shared = AgentHarnessRouter()

    private(set) var lastChoice: AgentHarnessChoice?
    private var entries: [AgentHarnessMemory] = []
    private var lastCodingID: AgentHarnessID?
    private var persistEnabled = true

    private static var fileURL: URL {
        AppIdentity.applicationSupportDirectory.appendingPathComponent("agent-harness-history.json")
    }

    private init() {
        entries = Self.load()
        if let last = entries.last(where: { $0.intentClass == AgentIntentClass.coding.rawValue }),
           let id = AgentHarnessID(rawValue: last.harnessID), id != .local {
            lastCodingID = id
        }
    }

    func choose(for text: String) -> AgentHarnessChoice {
        let intent = Self.intent(for: text)
        let choice: AgentHarnessChoice
        if let named = Self.explicitHarness(in: text) {
            choice = finalize(named, source: .explicit)
        } else if intent == .stayLocal {
            choice = finalize(.local, source: .explicit)
        } else if intent == .coding, let remembered = lastCodingFromHistory() {
            choice = finalize(remembered, source: .history)
        } else if intent == .coding, let session = lastCodingID {
            choice = finalize(session, source: .session)
        } else if intent == .coding, Settings.shared.agentBackend == .acp {
            let id = Self.harness(forCLI: Settings.shared.acpBackendID) ?? .claude
            choice = finalize(id, source: .settings)
        } else {
            choice = finalize(.local, source: .settings)
        }
        // Named / coding picks stay in memory even when the CLI is missing, so the
        // next similar ask can reuse them. Local calendar/click never writes history.
        if choice.id != .local {
            record(choice, snippet: text, intent: intent == .stayLocal ? .coding : intent)
        }
        return choice
    }

    func record(_ choice: AgentHarnessChoice, snippet: String, intent: AgentIntentClass) {
        lastChoice = choice
        guard choice.id != .local else { return }
        lastCodingID = choice.id
        let entry = AgentHarnessMemory(
            snippet: snippet.trimmingCharacters(in: .whitespacesAndNewlines),
            intentClass: intent.rawValue,
            harnessID: choice.id.rawValue,
            at: Date()
        )
        entries.append(entry)
        if entries.count > 80 { entries = Array(entries.suffix(80)) }
        save()
    }

    /// Self-tests must not wipe the user's on-disk history.
    func resetForTesting() {
        persistEnabled = false
        entries = []
        lastChoice = nil
        lastCodingID = nil
    }

    func restorePersistence() {
        persistEnabled = true
        entries = Self.load()
    }

    static func intent(for text: String) -> AgentIntentClass {
        let lowered = text.lowercased()
        if stayLocalMarks.contains(where: { lowered.contains($0) }) {
            return .stayLocal
        }
        if codingMarks.contains(where: { lowered.contains($0) }) {
            return .coding
        }
        return .general
    }

    static func explicitHarness(in text: String) -> AgentHarnessID? {
        let lowered = text.lowercased()
        let localMarks = [
            "do it locally", "do this locally", "use local", "locally only",
            "don't use an external", "do not use an external",
            "without an external agent", "no external agent",
        ]
        if localMarks.contains(where: { lowered.contains($0) }) { return .local }

        if lowered.contains("claude code") || lowered.contains("use claude")
            || lowered.contains("ask claude") || lowered.contains("in claude") {
            return .claude
        }
        if lowered.contains("qwen code") || lowered.contains("use qwen")
            || lowered.contains("ask qwen") || lowered.contains("in qwen") {
            return .qwen
        }
        if lowered.contains("opencode") || lowered.contains("open code") {
            return .opencode
        }
        if lowered.contains("codex") { return .codex }
        return nil
    }

    private func finalize(
        _ id: AgentHarnessID,
        source: AgentHarnessSource
    ) -> AgentHarnessChoice {
        if id == .local {
            let choice = AgentHarnessChoice(
                id: .local, source: source, available: true, fallbackToLocal: false, note: ""
            )
            lastChoice = choice
            return choice
        }
        let available = ACPAgentBackend.isOnPATH(id.acpCLI)
        let note = available
            ? ""
            : "\(id.displayName) isn’t installed, so I used local tools. Install it or pick another coding agent in Settings ▸ Agent."
        let choice = AgentHarnessChoice(
            id: id,
            source: source,
            available: available,
            fallbackToLocal: !available,
            note: note
        )
        lastChoice = choice
        return choice
    }

    private func lastCodingFromHistory() -> AgentHarnessID? {
        guard let last = entries.last(where: {
            $0.intentClass == AgentIntentClass.coding.rawValue
                && $0.harnessID != AgentHarnessID.local.rawValue
        }) else { return nil }
        return AgentHarnessID(rawValue: last.harnessID)
    }

    private static func harness(forCLI cli: String) -> AgentHarnessID? {
        AgentHarnessID.allCases.first { $0.acpCLI == cli && $0 != .local }
    }

    private func save() {
        guard persistEnabled else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private static func load() -> [AgentHarnessMemory] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? decoder.decode([AgentHarnessMemory].self, from: data)
        else { return [] }
        return entries
    }

    private static let stayLocalMarks = [
        "calendar", "agenda", "what’s on", "whats on",
        "gmail", "inbox", "email", "mail",
        "google drive", "drive file", "google docs", "google doc",
        "click", "type ", "tap the", "inspect",
        "chrome", "safari", "frontmost", "what app",
        "action item", "decision",
    ]

    private static let codingMarks = [
        "investigate", "fix the", "fix this", "write a test", "write tests",
        "run the tests", "failing test", "failing build", "the build",
        "open the project", "this repo", "the repo", "codebase",
        "refactor", "implement", "pull request", "work on this",
        "while i continue",
    ]
}
