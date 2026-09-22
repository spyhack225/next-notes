import Foundation
import Observation

/// Which tools a background listener is even allowed to name, and what one turn sees.
///
/// Reads are deliberately excluded. The watcher is not planning — it is noticing — and a
/// card under the notch offering to *search your mail* is noise that gets the whole feature
/// switched off. Only things that would actually happen are worth interrupting somebody for,
/// and those are exactly the classes that need an approval anyway.
enum FunctionCallCatalogue {
    /// The least consequential class the watcher may propose.
    static let minimumRisk = AgentRisk.modify

    /// The families a sentence somebody said out loud is allowed to reach.
    ///
    /// The registry also holds shell, filesystem, computer-control and browser tools, and
    /// none of them belong here. "Let's just delete that whole folder" is a thing people say
    /// in meetings; a card offering to do it is a card that will eventually be pressed by
    /// somebody who thought it was about something else. These three are the families where
    /// a spoken request and a tool call are the same thing — send a mail, put it in the
    /// diary, remember that — and they are the ones the approval card can show in full.
    static let allowedNamespaces: Set<AgentToolNamespace> = [.workspace, .schedule, .memory]

    /// How many tools one turn may be told about.
    ///
    /// Two things bound this. Needle shares its 8K context between the system prompt, the
    /// tool schemas and the turn, and `needle_init` fails outright when the static prefix
    /// does not fit. And the schemas are not free at run time either — measured on this Mac
    /// on 2026-09-19, one proposal took 126 ms with two tools declared, 0.97 s with eight
    /// and about four seconds with fourteen. A short list is not a compromise here; it is
    /// the difference between a card that arrives while the sentence is still in the air and
    /// one that arrives after the subject has changed.
    static let maxTools = 8

    /// What people actually say out loud, most often first, so the cap bites the long tail
    /// rather than Gmail. Anything not named here keeps its place behind these.
    static let spokenOrder = [
        "send_email", "create_event", "draft_email", "create_doc",
        "schedule.create", "append_doc", "memory.remember", "reply_email",
    ]

    @MainActor
    static func current(registry: AgentToolRegistry = .shared) -> [FunctionCallTool] {
        let tools = registry.tools(upTo: .privileged)
            .filter { $0.risk >= minimumRisk && allowedNamespaces.contains($0.namespace) }
            .sorted { lhs, rhs in
                let left = spokenOrder.firstIndex(of: lhs.id) ?? spokenOrder.count
                let right = spokenOrder.firstIndex(of: rhs.id) ?? spokenOrder.count
                if left != right { return left < right }
                // Native before whatever an MCP server or Composio added.
                if (lhs.source == .native) != (rhs.source == .native) { return lhs.source == .native }
                return lhs.id < rhs.id
            }
            .prefix(maxTools)
        return tools.map(descriptor(for:))
    }

    static func descriptor(for tool: AgentTool) -> FunctionCallTool {
        FunctionCallTool(
            id: tool.id,
            description: tool.description,
            parameters: tool.parameters.map {
                FunctionCallTool.Parameter(
                    name: $0.name,
                    description: $0.description,
                    isRequired: $0.isRequired,
                    shape: shape(of: $0)
                )
            }
        )
    }

    /// What a parameter will actually accept.
    ///
    /// Read off the catalogue's own `Kind` where it says so, and off the wording where it
    /// does not: `to` and `attendees` are declared `.list`, which is true and does not say
    /// they are lists *of addresses* — and "Marcus" is the answer that difference lets
    /// through.
    static func shape(of parameter: WorkspaceTool.Parameter) -> FunctionCallTool.Shape {
        let name = parameter.name.lowercased()
        let text = "\(name) \(parameter.description)".lowercased()
        // Before the email test, because `message_id` mentions an email and is not one.
        // These reach the API as handles — `docs +write --document <id>` — and a value that
        // is not a handle is not an approximate answer, it is a different kind of thing.
        if name == "id" || name.hasSuffix("_id") || name.hasSuffix("_ids") {
            return .identifier
        }
        if text.contains("address") || text.contains("email") || text.contains("recipient")
            || text.contains("attendee") {
            return .email
        }
        switch parameter.kind {
        case .date: return .dateTime
        case .multiline: return .longText
        case .list, .text: return .text
        }
    }
}

/// Which engine is doing the listening, whether it is ready, and what the last turn cost.
///
/// Feature-local on purpose: this is three switches and a status, and `Settings` is a hot
/// file shared by ten workstreams. `AgentIdentityStore` and `PersonaStore` already establish
/// the pattern — a small `@Observable` behind its own JSON file under Application Support.
@Observable
@MainActor
final class FunctionCallStore {
    static let shared = FunctionCallStore()
    static let fileName = "function-calling.json"

    /// What the Settings row and the self-test both read.
    enum Status: Equatable, Sendable {
        case off
        /// Nothing can run: no engine downloaded and no local model either.
        case unavailable(String)
        case downloading(Double)
        /// Something can run. `noticesMeetings` is false when the meeting half of the
        /// feature is switched off, which is a different thing from not working — the
        /// agent conversation still raises cards — and has to read differently, because a
        /// row saying "Ready" over an inert meeting path is the app telling the user
        /// something untrue about itself.
        case ready(FunctionCallBackend, noticesMeetings: Bool)
        case problem(String)

        var isReady: Bool {
            switch self {
            case .ready: true
            case .off, .unavailable, .downloading, .problem: false
            }
        }

        /// One plain sentence. No model names, no file sizes, no "backend".
        var sentence: String {
            switch self {
            case .off:
                return "Off. Next Notes will not offer to do things while you talk."
            case .unavailable(let why):
                return why
            case .downloading(let fraction):
                return "Getting ready\u{2026} \(Int(fraction * 100))%"
            case .ready(let backend, let noticesMeetings):
                let engine = switch backend {
                case .needle:
                    "Ready. Next Notes listens for things it could do and asks first."
                case .localModel:
                    "Ready, using the model already on this Mac. A little slower."
                }
                guard !noticesMeetings else { return engine }
                return engine + " In meetings it stays quiet \u{2014} switch on \u{201c}"
                    + Self.meetingToggleTitle + "\u{201d} below to change that."
            case .problem(let why):
                return why
            }
        }

        /// Named once so the sentence above and the switch itself cannot drift apart.
        static let meetingToggleTitle = "Notice things during a meeting too"
    }

    /// Whether the watcher runs at all. On by default: the feature never does anything
    /// without a person pressing a button, so the cost of it being on is a card.
    ///
    /// Written through a method rather than a `didSet`, because `@Observable` rewrites a
    /// stored property into accessors and a property observer on top of that is a second
    /// mechanism doing the same job.
    private(set) var isEnabled: Bool

    /// Whether the user has asked for the fast engine to be fetched. Nothing downloads
    /// 36 MB behind someone's back on a metered connection.
    private(set) var wantsFastEngine: Bool

    func setEnabled(_ value: Bool) {
        guard value != isEnabled else { return }
        isEnabled = value
        persist()
        Task { await refreshStatus() }
    }

    func setWantsFastEngine(_ value: Bool) {
        guard value != wantsFastEngine else { return }
        wantsFastEngine = value
        persist()
    }

    /// Whether the meeting half may run.
    ///
    /// Deliberately not a switch of this feature's own. The user already has one — "Listen
    /// for requests during a meeting" — and it means exactly this; a second one that had to
    /// be found separately would be a way of ignoring the first. What was wrong before was
    /// not that this feature deferred to it, but that it deferred silently: the row said
    /// "Ready" while `FunctionCallWatcher.ingest` returned on the first line, and the switch
    /// lived in a different tab under a different name. So it is surfaced here, in the
    /// section that claims to be ready, rather than assumed.
    var noticesMeetings: Bool {
        noticesMeetingsOverrideForTesting ?? Settings.shared.agentLiveDuringMeeting
    }

    /// Self-tests only. The live `ingest` path used to be skipped on any Mac where the
    /// meeting switch happened to be off — which was every Mac, since it is off by default —
    /// so the one path the feature exists for had never been run end to end. This drives it
    /// without writing to the user's real settings from a test process.
    @ObservationIgnored var noticesMeetingsOverrideForTesting: Bool?

    func setNoticesMeetings(_ value: Bool) {
        guard value != Settings.shared.agentLiveDuringMeeting else { return }
        Settings.shared.agentLiveDuringMeeting = value
        Task { await refreshStatus() }
    }

    private(set) var status: Status = .off
    /// Seconds for the last completed proposal, whichever backend ran it.
    private(set) var lastLatency: TimeInterval?
    private(set) var lastBackend: FunctionCallBackend?
    /// How many cards this launch has raised. The Settings row says "asked 3 times today"
    /// rather than showing a counter nobody can interpret.
    private(set) var proposalsRaised = 0

    private let fileURL: URL

    init(directory: URL? = nil) {
        let root: URL
        if let directory {
            root = directory
        } else if SelfTest.isRunning {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "NextNotesSelfTest-fc-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        } else {
            root = AppIdentity.applicationSupportDirectory
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent(Self.fileName)

        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            isEnabled = saved.isEnabled
            wantsFastEngine = saved.wantsFastEngine
        } else {
            isEnabled = true
            wantsFastEngine = false
        }
    }

    // MARK: - Status

    func setStatus(_ status: Status) { self.status = status }

    func noteProposal(latency: TimeInterval, backend: FunctionCallBackend) {
        lastLatency = latency
        lastBackend = backend
        proposalsRaised += 1
    }

    /// Re-reads what is actually on disk. Cheap, and the answer changes when a download
    /// finishes or the user deletes the notes model.
    func refreshStatus() async {
        guard isEnabled else { return setStatus(.off) }
        let meetings = noticesMeetings
        if NeedleModels.isDownloaded, NeedleModels.isSupportedHardware {
            return setStatus(.ready(.needle, noticesMeetings: meetings))
        }
        let fallback = LocalModelFunctionCallProposer()
        if await fallback.unavailableReason == nil {
            return setStatus(.ready(.localModel, noticesMeetings: meetings))
        }
        setStatus(.unavailable(
            "Nothing on this Mac can do this yet. Download the fast listening model, or "
                + "the model that writes your notes, in Models settings."
        ))
    }

    /// Fetches the fast engine, reporting progress into `status`.
    ///
    /// The Settings row that calls this is not this workstream's to write; see the report.
    func downloadFastEngine() async {
        guard NeedleModels.isSupportedHardware else {
            return setStatus(.unavailable("Fast listening needs an Apple silicon Mac."))
        }
        setWantsFastEngine(true)
        setStatus(.downloading(0))
        do {
            try await NeedleModels.download { fraction in
                Task { @MainActor in FunctionCallStore.shared.setStatus(.downloading(fraction)) }
            }
            await refreshStatus()
        } catch {
            setStatus(.problem(error.localizedDescription))
        }
    }

    /// The proposer to use right now, or nil when nothing can run.
    func resolveProposer() async -> (any FunctionCallProposer)? {
        if NeedleModels.isDownloaded, NeedleModels.isSupportedHardware {
            let needle = NeedleFunctionCallProposer()
            if await needle.unavailableReason == nil { return needle }
        }
        let fallback = LocalModelFunctionCallProposer()
        return await fallback.unavailableReason == nil ? fallback : nil
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var isEnabled: Bool
        var wantsFastEngine: Bool
    }

    private func persist() {
        let snapshot = Snapshot(isEnabled: isEnabled, wantsFastEngine: wantsFastEngine)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
