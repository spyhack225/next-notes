import Foundation
import Observation

// §8.2 — two-step ingestion consent.
//
// Reads auto-run, and that stays correct for the person's own Mac: files and search were
// never the problem. What is wrong is the first time a *newly connected account's* personal
// data flows in — an email thread mentioning a family fact lands in a reply, the reply is
// indexed, and the extraction has turned somebody else's mail into a fact about this
// household without anybody ever having been asked. So the rule, per §8.2: the first
// ingestion from a newly connected account always runs look → show findings → "may I use
// this?", even under auto-allow reads. The gate is per-account-first-use, not per-tool: once
// the person has said yes to one read, they have said it about the account, and the reads
// run as they always did.
//
// The ask is the existing card, not a new surface: `PermissionGate.ask` with a request whose
// body is the findings. Saying no is a real answer — the findings are withheld, a line says
// exactly what was and was not used, and the gate stays armed for the next time. Where
// nobody can answer (a scheduled run), nothing is looked up at all and the refusal says so:
// a consent path that silently ingests when nobody can answer is the bug this gate exists
// for.

/// One account's reviewed state, persisted so a relaunch does not ask twice.
struct FirstIngestionRecord: Codable, Equatable, Sendable {
    /// The account, as the app can name it. For Workspace this is the credential set
    /// `gws auth status` describes — the CLI exposes no address, and its single credential
    /// set is the account it acts as.
    var account: String
    var reviewedAt: Date
    /// The tool the person saw the findings through, for the record.
    var viaTool: String
}

/// Per-account first-use state, and the consent card for a first look.
///
/// Shaped like the memory review's own stores: one replaceable JSON file, a temp directory
/// under a self-test, and a seam (`unreviewedWorkspaceAccount`) the self-test and the
/// production CLI resolve differently.
@MainActor
@Observable
final class FirstIngestionGate {
    static let shared = FirstIngestionGate()

    static let fileName = "first-ingestion.json"

    private(set) var records: [FirstIngestionRecord] = []

    let fileURL: URL?
    private let now: () -> Date

    private init() {
        let directory: URL
        if SelfTest.isRunning {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("NextNotesSelfTest-first-use-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
        } else {
            directory = AppIdentity.applicationSupportDirectory
        }
        fileURL = directory.appendingPathComponent(Self.fileName)
        self.now = Date.init
        load()
    }

    func isReviewed(account: String) -> Bool {
        guard !account.isEmpty else { return false }
        return records.contains { $0.account == account }
    }

    /// The person said yes. From here on this account's reads run as any other read.
    func markReviewed(account: String, viaTool: String) {
        guard !account.isEmpty else { return }
        guard !isReviewed(account: account) else { return }
        records.append(FirstIngestionRecord(account: account, reviewedAt: now(), viaTool: viaTool))
        persist()
    }

    // MARK: - Workspace

    /// The account this Mac is signed in to Workspace as, when its first use is still owed.
    /// Nil when nothing is connected, or the connection has already had its first look.
    static func unreviewedWorkspaceAccount() async -> String? {
        let state = await GoogleWorkspaceCLI.shared.authState()
        guard case .signedIn(let method) = state else { return nil }
        let account = "google-workspace:\(method)"
        return shared.isReviewed(account: account) ? nil : account
    }

    /// What the consent card says it is asking about. One service name per tool, because
    /// "your mail" and "your calendar" are different rooms to a person.
    static func serviceLabel(forToolID toolID: String) -> String {
        switch toolID {
        case "search_email", "reply_email": "your mail"
        case "get_agenda": "your calendar"
        case "find_drive_files", "upload_to_drive": "your Drive"
        case "read_doc", "create_doc", "append_doc": "your documents"
        default: "your account"
        }
    }

    /// The consent request itself: the look's findings as the card's body, so the person
    /// decides on what was actually found, not on the idea of it. `toolID` is deliberately
    /// not a real tool's id — the review card then renders the findings as one long field
    /// instead of dressing them up as an argument review.
    static func consentRequest(
        toolID: String, account: String, findings: String
    ) -> PermissionRequest {
        let body = Self.clippedFindings(of: findings)
        return PermissionRequest(
            id: "first-use-\(UUID().uuidString)",
            toolID: "first_use_consent",
            title: "May I use what I found in \(serviceLabel(forToolID: toolID))?",
            detail: "First time with this account — nothing is kept until you say so.",
            risk: .read,
            arguments: ["findings": body],
            trigger: .firstUse(account)
        )
    }

    /// The line when the person said no. It states exactly what did happen (the look) and
    /// what did not (the use), in the shape §8.2 asks of every failure card.
    static func notUsedLine(toolID: String) -> String {
        "I looked in \(serviceLabel(forToolID: toolID)), and you chose not to use it — so "
            + "nothing from it is remembered, indexed or written down. Say the word next time "
            + "and I will ask again."
    }

    /// The line when there was nobody to ask. The look did not happen at all: an unattended
    /// run cannot show findings to anybody, so looking would be ingesting without a yes.
    static func noConsentPathLine(toolID: String) -> String {
        "I did not use \(serviceLabel(forToolID: toolID)): the first time an account is "
            + "read, the findings go to you first, and there was nobody here to show them to."
    }

    /// The findings as the card's body. Long enough to recognise, short enough to read
    /// under the notch.
    static func clippedFindings(of findings: String) -> String {
        let flat = findings.trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > 600 else { return flat }
        return flat.prefix(599).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    // MARK: - Disk

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let rows = try? JSONDecoder().decode([FirstIngestionRecord].self, from: data) else { return }
        records = rows
    }

    private func persist() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
