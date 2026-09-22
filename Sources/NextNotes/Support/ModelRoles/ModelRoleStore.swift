import Foundation
import Observation

/// The four jobs a person can give a different model to.
///
/// Named for what they *do*, not for how they are implemented: someone who has never heard
/// of a parameter count still knows the difference between "answer me", "drive my Mac",
/// "write code" and "summarise a meeting".
enum ModelRole: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Answers, conversation and tool planning. The default for everything.
    case agent
    /// Turns spoken to "click that", "open Safari", "read the front window".
    case computerUse
    /// Sustained work in a project — the coding agents.
    case coding
    /// Writes notes from a meeting transcript.
    case meetingNotes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .agent: "Everyday assistant"
        case .computerUse: "Controlling your Mac"
        case .coding: "Writing code"
        case .meetingNotes: "Meeting notes"
        }
    }

    var summary: String {
        switch self {
        case .agent:
            "Answers questions, reads your calendar and mail, and decides what to do next."
        case .computerUse:
            "Clicks, types and reads what’s on screen when you ask for it."
        case .coding:
            "Works inside a project for longer stretches."
        case .meetingNotes:
            "Writes notes from a meeting transcript when a meeting ends."
        }
    }

    /// Whether this job can actually be done by a choice of this kind.
    ///
    /// The picker and `resolve` both ask this, so no row can ever show a green dot for
    /// something the app structurally cannot carry out. Two limits are real rather than
    /// cosmetic, and both were being hidden:
    ///
    /// * The model runtime inside Next Notes loads exactly one of your own model files at a
    ///   time — the one `InstalledModelLibrary.activeAgentModelID` names. Pointing a second
    ///   job at a different file cannot work; that job would quietly get the assistant's
    ///   model instead. So a file from the library belongs to the everyday assistant.
    /// * An agent app is a separate program handed a task in a project folder. It can take
    ///   coding work, which is what `AgentHarnessRouter` delegates. It never answers an
    ///   everyday question here.
    ///
    /// Codex is the one exception, and it is a real one rather than a courtesy: it ships a
    /// helper app that clicks and types on this Mac, and `CodexComputerUse` hands a request
    /// to it. The others were checked for the same thing and do not have one — Claude ships
    /// no screen-driving helper beside its app, and the `claude` CLI offers no such command
    /// — so they still cannot take this job however thoroughly they are installed. Whether
    /// Codex can do it *right now* is a separate question, asked by `resolve`; this only
    /// says the job is the right shape for it.
    func canUse(_ choice: ModelRoleChoice) -> Bool {
        switch choice {
        case .builtIn, .appleFoundation, .localServer, .cloud: true
        case .installedModel: self == .agent
        case .app(let harness):
            self == .coding || (self == .computerUse && harness == .codex)
        }
    }

    /// Why a choice of this kind cannot do this job, as a sentence to put on screen.
    /// Nil when it can. Nothing here is a fault the person can put right, so none of it is
    /// phrased as a warning.
    func unsuitedNote(for choice: ModelRoleChoice) -> String? {
        guard !canUse(choice) else { return nil }
        switch choice {
        case .installedModel:
            return "Next Notes can run one of your own model files at a time, and that one "
                + "belongs to your everyday assistant — so it uses its built-in model here."
        case .app(let harness):
            switch self {
            case .computerUse:
                return "\(harness.displayName) works on code in a project and can't see or "
                    + "click the windows on this Mac, so Next Notes uses its own model "
                    + "to do that."
            case .agent, .coding, .meetingNotes:
                return "\(harness.displayName) works on code in a project, not everyday "
                    + "questions — so Next Notes uses its built-in model here."
            }
        case .builtIn, .appleFoundation, .localServer, .cloud:
            return nil
        }
    }
}

/// What a role has been pointed at.
///
/// Stored as a short text token rather than a nested structure, because it lives in
/// UserDefaults and has to survive the app gaining new kinds of choices without a
/// migration.
enum ModelRoleChoice: Codable, Sendable, Hashable {
    /// The model that comes with Next Notes. Always the floor, never unavailable for long.
    case builtIn
    /// Apple's on-device model, when Apple Intelligence is switched on.
    case appleFoundation
    /// A model file in the library on this Mac, by `InstalledLocalModel.id`.
    case installedModel(id: String)
    /// A model held by Ollama, LM Studio or another app running here.
    case localServer(endpointID: String, modelID: String)
    /// A model reached over the internet through OpenRouter. Which one is named in
    /// Models settings and stays there: carrying a copy here only created two places
    /// that could disagree about the same model.
    case cloud
    /// An agent app already installed on this Mac — Claude Code, Codex, and the rest.
    case app(AgentHarnessID)

    // MARK: Token form

    var token: String {
        switch self {
        case .builtIn: "builtin"
        case .appleFoundation: "apple"
        case .installedModel(let id): "installed:\(id)"
        case .localServer(let endpointID, let modelID): "server:\(endpointID)|\(modelID)"
        case .cloud: "cloud"
        case .app(let harness): "app:\(harness.rawValue)"
        }
    }

    /// Nil for anything unrecognised, so a token written by a newer build degrades to the
    /// role's default rather than to a crash.
    init?(token: String) {
        switch token {
        case "builtin": self = .builtIn; return
        case "apple": self = .appleFoundation; return
        case "cloud": self = .cloud; return
        default: break
        }
        guard let separator = token.firstIndex(of: ":") else { return nil }
        let kind = String(token[token.startIndex..<separator])
        let value = String(token[token.index(after: separator)...])
        switch kind {
        case "installed":
            guard !value.isEmpty else { return nil }
            self = .installedModel(id: value)
        case "server":
            guard let pipe = value.firstIndex(of: "|") else { return nil }
            let endpointID = String(value[value.startIndex..<pipe])
            let modelID = String(value[value.index(after: pipe)...])
            guard !endpointID.isEmpty, !modelID.isEmpty else { return nil }
            self = .localServer(endpointID: endpointID, modelID: modelID)
        case "cloud":
            // Tokens written by an earlier build carried the model id; it lives in
            // Models settings now, so the payload is read and discarded.
            self = .cloud
        case "app":
            guard let harness = AgentHarnessID(rawValue: value), harness != .local else { return nil }
            self = .app(harness)
        default:
            return nil
        }
    }

    init(from decoder: any Decoder) throws {
        let token = try decoder.singleValueContainer().decode(String.self)
        self = ModelRoleChoice(token: token) ?? .builtIn
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(token)
    }

    /// The agent app behind this choice, if it is one. Coding and computer-use routes need
    /// this; the model providers do not.
    var harness: AgentHarnessID? {
        if case .app(let harness) = self { return harness }
        return nil
    }
}

/// Everything resolution needs to know about this Mac, in one value so the decision itself
/// stays a pure function that a self-test can drive without a network or a model.
struct ModelRoleAvailability: Sendable, Equatable {
    var builtInModelReady: Bool = false
    var appleFoundationReady: Bool = false
    var installedModelIDs: Set<String> = []
    /// Endpoint id → the model ids that server is currently offering.
    var localServerModels: [String: Set<String>] = [:]
    /// Endpoint id → what to call it on screen.
    var localServerNames: [String: String] = [:]
    /// Agent apps that are actually runnable, not merely downloaded.
    var installedApps: Set<AgentHarnessID> = []
    /// An OpenRouter key and a chosen model.
    var cloudReady: Bool = false
    /// Whether handing a click to Codex would work right now — a different question from
    /// whether Codex is installed, because the part that drives the screen is a separate
    /// helper and it needs a signed-in account behind it.
    var codexComputerUse: CodexComputerUseReadiness = .codexMissing

    static let nothingInstalled = ModelRoleAvailability()
}

/// Why a role is not using what it was pointed at.
enum ModelRoleFallbackReason: Sendable, Equatable {
    /// It is using exactly what was chosen.
    case honoured
    /// It would work, but the app, server, key or file is not there right now. Something
    /// the person can put right, so the row draws attention to it.
    case notThere
    /// It could never do this job — see `ModelRole.canUse`. Nothing is missing and there is
    /// nothing to fix, so the row explains rather than warns.
    case notThisJob
}

/// What a role will actually use for the next call, and what to tell the person if that is
/// not what they picked.
struct ModelRoleResolution: Sendable, Equatable {
    let role: ModelRole
    let requested: ModelRoleChoice
    let effective: ModelRoleChoice
    /// Plain language, or nil when the choice was honoured.
    let note: String?
    let reason: ModelRoleFallbackReason

    init(
        role: ModelRole,
        requested: ModelRoleChoice,
        effective: ModelRoleChoice,
        note: String?,
        reason: ModelRoleFallbackReason = .honoured
    ) {
        self.role = role
        self.requested = requested
        self.effective = effective
        self.note = note
        self.reason = reason
    }

    var didFallBack: Bool { requested != effective }

    /// Something the person could act on — an app to install, a key to add, a server to
    /// start. A job that simply is not done by that kind of model is not a problem.
    var needsAttention: Bool { reason == .notThere }
}

/// Which model does which job.
///
/// Feature-local on purpose: it keeps its own three keys in UserDefaults rather than
/// growing `Settings`, in the same way `PersonaStore` and `AgentIdentityStore` do.
///
/// The rule the whole file exists to enforce: **a role that cannot be honoured falls back
/// to the model that came with the app.** Not to an error, not to silence. Someone who
/// picked Claude Code and then uninstalled it should still get an answer, and should be
/// told in one sentence why it came from somewhere else.
@MainActor
@Observable
final class ModelRoleStore {
    static let shared = ModelRoleStore()

    private let defaults: UserDefaults
    private let catalog: LocalRuntimeCatalog

    private(set) var availability: ModelRoleAvailability
    private(set) var isCheckingAvailability = false

    private var choices: [ModelRole: ModelRoleChoice]

    init(
        defaults: UserDefaults = .standard,
        catalog: LocalRuntimeCatalog? = nil,
        availability: ModelRoleAvailability? = nil
    ) {
        self.defaults = defaults
        self.catalog = catalog ?? LocalRuntimeCatalog.shared
        self.availability = availability ?? .nothingInstalled
        var stored: [ModelRole: ModelRoleChoice] = [:]
        for role in ModelRole.allCases {
            if let token = defaults.string(forKey: Self.key(for: role)),
               let choice = ModelRoleChoice(token: token) {
                stored[role] = choice
            }
        }
        choices = stored
        if availability == nil {
            seedAvailabilityFromDisk()
            adoptExistingAgentModelChoice()
        }
    }

    /// Someone who already chose an agent model before this screen existed must not be
    /// silently moved back to the built-in one. The first time the assistant role is read,
    /// it takes over whatever `Settings.agentModelProvider` already said, and the write-back
    /// in `setChoice` keeps the two in step from then on.
    private func adoptExistingAgentModelChoice() {
        guard choices[.agent] == nil else { return }
        let adopted: ModelRoleChoice? = switch Settings.shared.agentModelProvider {
        case .openRouter: .cloud
        case .appleFoundation: .appleFoundation
        case .localServer, .gemma4E4B: nil
        }
        guard let adopted else { return }
        choices[.agent] = adopted
        defaults.set(adopted.token, forKey: Self.key(for: .agent))
    }

    /// What can be answered without a network call or an await. Without this the very first
    /// turn after launch would read an empty snapshot and report that everything the user
    /// picked is missing — which is a lie that lasts until Settings is opened.
    private func seedAvailabilityFromDisk() {
        availability.builtInModelReady = NotesModels.isDownloaded
        availability.installedModelIDs = Set(InstalledModelLibrary.shared.models.map(\.id))
        availability.installedApps = Self.installedAgentApps()
        availability.localServerNames = catalog.displayNamesByEndpoint
        // Filesystem only, so it is honest from the first turn rather than from the first
        // time Settings is opened.
        availability.codexComputerUse = CodexComputerUse.probe()
    }

    private static func key(for role: ModelRole) -> String { "modelRoles.\(role.rawValue)" }

    // MARK: - Defaults

    /// Exactly what the product asks for: answers and the assistant run on the model that
    /// came with the app; driving the Mac goes to Codex; code goes to Claude Code. Each of
    /// the last two comes back to the built-in model when that app is not installed, which
    /// is what `resolve` does rather than what is stored here.
    static func defaultChoice(for role: ModelRole) -> ModelRoleChoice {
        switch role {
        case .agent: .builtIn
        case .computerUse: .app(.codex)
        case .coding: .app(.claude)
        case .meetingNotes: .builtIn
        }
    }

    // MARK: - Reading and writing the choice

    func choice(for role: ModelRole) -> ModelRoleChoice {
        choices[role] ?? Self.defaultChoice(for: role)
    }

    func setChoice(_ choice: ModelRoleChoice, for role: ModelRole) {
        choices[role] = choice
        defaults.set(choice.token, forKey: Self.key(for: role))
        guard role == .agent else { return }
        // The agent role decides which model file the in-process runtime loads.
        switch choice {
        case .installedModel(let id):
            InstalledModelLibrary.shared.activeAgentModelID = id
        case .builtIn:
            InstalledModelLibrary.shared.activeAgentModelID = InstalledModelLibrary.builtInID
        default:
            break
        }
        mirrorAgentRoleIntoSettings(choice)
    }

    /// Ask, the meeting reconciler and the voice turn were all written against
    /// `Settings.agentModelProvider`, and they are the same decision as the assistant role.
    /// Rather than leave two switches that disagree, the role writes through to the old one
    /// — so a path that has not been touched still follows what the user picked.
    private func mirrorAgentRoleIntoSettings(_ choice: ModelRoleChoice) {
        let settings = Settings.shared
        switch choice {
        case .builtIn, .installedModel, .app:
            // An agent app is a separate process reached through the harness router; the
            // model that answers here is still the built-in one.
            settings.agentModelProvider = .gemma4E4B
        case .appleFoundation:
            settings.agentModelProvider = .appleFoundation
        case .localServer:
            settings.agentModelProvider = .localServer
        case .cloud:
            settings.agentModelProvider = .openRouter
        }
    }

    // MARK: - Resolution

    /// The decision, with nothing behind it but the snapshot it is given. Every fallback in
    /// the app goes through here so there is one place to read and one place to test.
    static func resolve(
        role: ModelRole,
        choice: ModelRoleChoice,
        availability: ModelRoleAvailability
    ) -> ModelRoleResolution {
        func fallBack(_ note: String) -> ModelRoleResolution {
            ModelRoleResolution(
                role: role, requested: choice, effective: .builtIn, note: note, reason: .notThere
            )
        }
        func honour() -> ModelRoleResolution {
            ModelRoleResolution(role: role, requested: choice, effective: choice, note: nil)
        }

        // Asked first, and never mixed up with "it isn't installed". An agent app that is
        // sitting on this Mac still cannot answer an everyday question or click a window,
        // and a second model file still cannot be loaded beside the assistant's. Reporting
        // either of those as honoured — a green dot, no sentence — was the exact failure
        // this screen exists to prevent.
        if let unsuited = role.unsuitedNote(for: choice) {
            return ModelRoleResolution(
                role: role, requested: choice, effective: .builtIn,
                note: unsuited, reason: .notThisJob
            )
        }

        switch choice {
        case .builtIn:
            return honour()

        case .appleFoundation:
            guard availability.appleFoundationReady else {
                return fallBack(
                    "Apple Intelligence isn’t switched on, so Next Notes will use its built-in model."
                )
            }
            return honour()

        case .installedModel(let id):
            guard availability.installedModelIDs.contains(id) else {
                return fallBack(
                    "That model isn’t on this Mac any more, so Next Notes will use its built-in model."
                )
            }
            return honour()

        case .localServer(let endpointID, let modelID):
            let name = availability.localServerNames[endpointID] ?? "That app"
            guard let offered = availability.localServerModels[endpointID], !offered.isEmpty else {
                return fallBack("\(name) isn’t running, so Next Notes will use its built-in model.")
            }
            guard offered.contains(modelID) else {
                return fallBack(
                    "\(name) no longer has “\(modelID)”, so Next Notes will use its built-in model."
                )
            }
            return honour()

        case .cloud:
            guard availability.cloudReady else {
                return fallBack(
                    "There’s no online model set up yet, so Next Notes will use its built-in model."
                )
            }
            return honour()

        case .app(let harness):
            // Driving the Mac is not the same test as writing code. Codex can be installed,
            // on PATH and perfectly able to open a project, and still not be able to touch
            // the screen — the helper that does that is a separate download behind a
            // sign-in. Asking the coding question here would paint this row green and then
            // fail at the moment the person said "click that".
            if role == .computerUse {
                let readiness = availability.codexComputerUse
                guard readiness.isReady else {
                    return fallBack(readiness.note ?? "Codex can’t control this Mac right now.")
                }
                return honour()
            }
            guard availability.installedApps.contains(harness) else {
                return fallBack(
                    "\(harness.displayName) isn’t installed on this Mac, "
                        + "so Next Notes will use its own model."
                )
            }
            return honour()
        }
    }

    func resolution(for role: ModelRole) -> ModelRoleResolution {
        Self.resolve(role: role, choice: choice(for: role), availability: availability)
    }

    // MARK: - One name for a choice, on every screen

    /// The name the UI should show for a choice, shared by every screen so replacing the
    /// default brain renames it everywhere instead of leaving one row on the old name.
    ///
    /// `.builtIn` names the file the runtime actually loads — the assistant's active model —
    /// not necessarily the file that shipped. That is why the Models tab can show
    /// "MiniCPM5-2B" on the built-in row: the row names what will run. A missing library
    /// entry falls back the same way the runtime does: to the model that ships.
    func displayName(for choice: ModelRoleChoice, role: ModelRole) -> String {
        switch choice {
        case .builtIn:
            let activeID = InstalledModelLibrary.shared.activeAgentModelID
            if activeID != InstalledModelLibrary.builtInID,
               let active = InstalledModelLibrary.shared.model(withID: activeID) {
                return active.displayName
            }
            return InstalledModelLibrary.shared.builtIn?.displayName ?? NotesModels.spec.displayName
        case .installedModel(let id):
            if let model = InstalledModelLibrary.shared.model(withID: id) {
                return model.displayName
            }
            return displayName(for: .builtIn, role: role)
        case .appleFoundation:
            return "Apple's built-in intelligence"
        case .localServer(_, let modelID):
            return modelID
        case .cloud:
            let configured = role == .meetingNotes
                ? Settings.shared.openRouterNotesModelID
                : Settings.shared.openRouterAgentModelID
            return configured.isEmpty ? "An online model" : configured
        case .app(let harness):
            return harness.displayName
        }
    }

    /// The name the UI should show for a role: the effective choice's name, so the label
    /// matches what the next run will actually use rather than what was picked.
    func displayName(for role: ModelRole) -> String {
        displayName(for: resolution(for: role).effective, role: role)
    }

    // MARK: - The provider a call path actually uses

    /// The model that will answer for this role, right now.
    ///
    /// Deliberately **not** driven by the stored snapshot. `resolution` describes what
    /// Settings last saw, and a server can stop between the Settings window closing and the
    /// question being asked — so every branch here checks the real thing and falls back to
    /// the built-in model on the spot. The two together are the contract: the screen says
    /// what it last knew, the call path proves it.
    ///
    /// An agent app never becomes an LLM provider — it is a separate process reached
    /// through `AgentHarnessRouter` — so a role pointed at one answers with the built-in
    /// model, and the harness route takes the app.
    func provider(for role: ModelRole) async -> (any LLMProvider)? {
        let selected = choice(for: role)
        // The same rule the screen states. Without this line a job pointed at a model file
        // it cannot load would silently be handed the assistant's model instead.
        guard role.canUse(selected) else { return await builtInProvider(for: role) }
        switch selected {
        case .localServer(let endpointID, let modelID):
            guard let endpoint = catalog.endpoint(id: endpointID) else {
                return await builtInProvider(for: role)
            }
            let provider = OpenAICompatibleLLMProvider(
                baseURL: endpoint.baseURL, modelID: modelID, serverName: endpoint.displayName
            )
            if await provider.unavailableReason == nil { return provider }
            return await builtInProvider(for: role)

        case .cloud:
            // Meeting notes uses its own OpenRouter model settings.
            let openRouterModelID = role == .meetingNotes
                ? Settings.shared.openRouterNotesModelID
                : Settings.shared.openRouterAgentModelID
            let openRouterContextTokens = role == .meetingNotes
                ? Settings.shared.openRouterNotesContextTokens
                : Settings.shared.openRouterAgentContextTokens
            if let provider = await LLMProviders.resolve(
                preferring: .openRouter,
                modelID: openRouterModelID,
                contextTokens: openRouterContextTokens
            ) { return provider }
            return await builtInProvider(for: role)

        case .appleFoundation:
            // `resolve` walks on to the built-in model when Apple Intelligence is off.
            return await LLMProviders.resolve(preferring: .appleFoundation)

        case .installedModel(let id):
            // The llama runtime loads whichever file the library points at. Only the
            // assistant role reaches this branch — `canUse` sent the others to the built-in
            // model above, rather than letting them take over the file it loads.
            guard InstalledModelLibrary.shared.model(withID: id) != nil else {
                return await builtInProvider(for: role)
            }
            if InstalledModelLibrary.shared.activeAgentModelID != id {
                InstalledModelLibrary.shared.activeAgentModelID = id
            }
            return await LLMProviders.resolve(preferring: .appLLM)

        case .builtIn, .app:
            return await builtInProvider(for: role)
        }
    }

    private func builtInProvider(for role: ModelRole) async -> (any LLMProvider)? {
        if role == .agent,
           InstalledModelLibrary.shared.activeAgentModelID != InstalledModelLibrary.builtInID,
           case .builtIn = choice(for: role) {
            InstalledModelLibrary.shared.activeAgentModelID = InstalledModelLibrary.builtInID
        }
        return await LLMProviders.resolve(preferring: .appLLM)
    }

    /// The configured local-server provider for the assistant role, built without probing.
    /// `LLMProviders.make(.localServer)` needs one synchronously.
    func localServerProviderForAgentRole() -> OpenAICompatibleLLMProvider? {
        guard case .localServer(let endpointID, let modelID) = choice(for: .agent),
              let endpoint = catalog.endpoint(id: endpointID) else { return nil }
        return OpenAICompatibleLLMProvider(
            baseURL: endpoint.baseURL, modelID: modelID, serverName: endpoint.displayName
        )
    }

    /// The agent app a coding turn should be handed to, or nil when there is none to hand
    /// it to and the turn stays here.
    var codingHarness: AgentHarnessID? { resolution(for: .coding).effective.harness }

    /// The agent app a "click that" turn should be handed to, or nil when the turn stays
    /// here and Next Notes' own computer tools do it.
    ///
    /// This reads the same resolution the dot draws, which is the point: if the row is green
    /// this returns Codex, and if the row is grey this returns nil. One answer, so the screen
    /// and the turn cannot disagree.
    var computerUseHarness: AgentHarnessID? { resolution(for: .computerUse).effective.harness }

    /// Whether the person actually chose something for this job, as opposed to never having
    /// opened the screen. The coding route needs the difference: "keep code on this Mac" is
    /// a decision, and it must not read the same as silence.
    func hasExplicitChoice(for role: ModelRole) -> Bool { choices[role] != nil }

    // MARK: - Which role a request belongs to

    /// Requests about the screen, the mouse and the keyboard belong to the computer-use
    /// role; everything conversational belongs to the assistant. Coding is not decided here
    /// — `AgentHarnessRouter` owns that, because it is a decision about *where* the work
    /// runs rather than which model answers.
    static func role(forUtterance text: String) -> ModelRole {
        let lowered = text.lowercased()
        return computerPatterns.contains(where: {
            lowered.range(of: $0, options: .regularExpression) != nil
        }) ? .computerUse : .agent
    }

    /// Whole words, and for the verbs the start of a sentence — the shape
    /// `AgentHarnessRouter.explicitHarness` already uses for the same kind of decision.
    ///
    /// Bare substrings were sending ordinary questions to this job: "what **type** of report
    /// should I write", "draft a **press** release", "**what app**roach should I take". That
    /// is not only the wrong model — someone who points the computer-use job at an online
    /// model would have watched a press release leave their Mac because of the word "press".
    ///
    /// Erring the other way is cheap. A request that lands on the everyday assistant can
    /// still click: the computer tools are offered to whichever model plans the turn. Only
    /// the choice of model is affected, so a missed match costs nothing a person would see.
    private static let computerPatterns: [String] = {
        let verbs = "click|double[- ]click|right[- ]click|tap|type|press|scroll|drag|swipe"
        // Up to four polite or joining words between the start of a sentence and the verb,
        // so "can you please click…" and "and then type…" are still instructions.
        let leadIn = #"(?:^|[.!?]\s+)(?:(?:please|now|then|and|also|can|could|would|will|you|next|first)\s+){0,4}"#
        return [
            leadIn + #"(?:"# + verbs + #")\b"#,
            #"\bon (?:my|the) screen\b"#,
            #"\bthe front(?:most)? window\b"#,
            #"\bfrontmost (?:app|window|application)\b"#,
            #"\bwh(?:at|ich) app (?:is|am i|do i have)\b"#,
            #"\btake a screenshot\b"#,
            #"\bscreenshot of\b"#,
            #"\bopen (?:safari|chrome|finder|system settings)\b"#,
            #"\b(?:read|inspect) (?:what(?:’|')?s |what is )?on (?:my|the) screen\b"#,
        ]
    }()

    // MARK: - Availability

    /// Re-asks this Mac what it has. Cheap, cancellable, and never on a turn's hot path:
    /// Settings calls it when it opens and when the user asks to check again, and the app
    /// calls it once at launch.
    func refreshAvailability() async {
        guard !isCheckingAvailability else { return }
        isCheckingAvailability = true
        defer { isCheckingAvailability = false }

        await catalog.refresh()
        InstalledModelLibrary.shared.refresh()

        var next = ModelRoleAvailability()
        next.builtInModelReady = await LLMProviders.make(.appLLM).unavailableReason == nil
        next.appleFoundationReady = await LLMProviders.make(.appleFoundation).unavailableReason == nil
        next.installedModelIDs = Set(InstalledModelLibrary.shared.models.map(\.id))
        next.localServerModels = catalog.modelIDsByEndpoint
        next.localServerNames = catalog.displayNamesByEndpoint
        next.cloudReady = await OpenRouterKeyStore.hasKeyAsync()
            && !Settings.shared.openRouterAgentModelID.isEmpty
        next.installedApps = Self.installedAgentApps()
        next.codexComputerUse = CodexComputerUse.probe()
        availability = next
    }

    /// An agent app counts as installed only when the thing that would actually be launched
    /// is on disk. A downloaded app whose ACP adapter is missing cannot run a turn, and
    /// saying it is ready would mean a failure at the moment the user asked for something.
    static func installedAgentApps() -> Set<AgentHarnessID> {
        var found: Set<AgentHarnessID> = []
        for harness in AgentHarnessID.allCases where harness != .local {
            if ACPAgentBackend.isOnPATH(harness.acpCLI) { found.insert(harness) }
        }
        return found
    }

    /// Lets a self-test drive resolution without touching this Mac.
    func overrideAvailabilityForTesting(_ value: ModelRoleAvailability) {
        availability = value
    }

    func setChoiceForTesting(_ choice: ModelRoleChoice, for role: ModelRole) {
        choices[role] = choice
    }

    /// In-memory only, so a self-test that drives the shared store can hand the person's own
    /// choices back exactly as it found them — including a role they had never set.
    func snapshotChoicesForTesting() -> [ModelRole: ModelRoleChoice] { choices }

    func restoreChoicesForTesting(_ snapshot: [ModelRole: ModelRoleChoice]) {
        choices = snapshot
    }
}

/// Which model answers one turn.
///
/// The one place the app asks "whose job is this". A voice turn stays on the built-in model
/// whatever the roles say — a cloud round trip in the middle of someone speaking is not a
/// conversation — and everything else goes to the role the request belongs to.
@MainActor
enum AgentModelRouting {
    static func provider(for prompt: String, voice: Bool) async -> (any LLMProvider)? {
        if voice { return await LLMProviders.resolve(preferring: .appLLM) }
        let role = ModelRoleStore.role(forUtterance: prompt)
        // P1-3: a long plan cannot hold on the on-device model. When the request looks
        // multi-step and an online model is configured and consented, continue there.
        // Voice never takes this path — see the early return above.
        if role == .agent, MultiStepPlanRouting.likelyMultiStep(prompt) {
            let ready = await OpenRouterKeyStore.hasKeyAsync()
                && !Settings.shared.openRouterAgentModelID.isEmpty
            let consent = Settings.shared.knowledgeGraphCloudConsent
            if ready && consent,
               let cloud = await LLMProviders.resolve(
                   preferring: .openRouter,
                   modelID: Settings.shared.openRouterAgentModelID,
                   contextTokens: Settings.shared.openRouterAgentContextTokens) {
                return cloud
            }
        }
        return await ModelRoleStore.shared.provider(for: role)
    }
}

// MARK: - P1-3 Long-plan routing (deterministic; no model call)

/// Whether a request looks like ≥3 steps, and where it should run.
///
/// The decision is deterministic: sequencers plus action verbs, with the single-step
/// shortcut (`AgentDirectIntent`) as the veto. A miss costs a slow local run; a false
/// positive costs an online round trip — so the shortcut wins over the heuristics.
enum MultiStepPlanRouting: Sendable {
    enum Route: String, Sendable, Equatable { case cloud, localWithWarning, local }

    /// Action words worth counting. Matched as a word prefix so "checking" counts
    /// for "check" without listing every form.
    static let verbs = [
        "open", "go", "find", "search", "check", "summarise", "summarize", "list",
        "send", "create", "read", "write", "book", "buy", "reserve", "plan",
        "schedule", "remind", "draft", "email", "look", "get", "show", "make",
        "add", "update",
    ]

    static func likelyMultiStep(_ text: String) -> Bool {
        let lowered = text.lowercased()
        // Sequencers: "then", "and then", "after", "afterwards". "and" alone is not
        // enough — it joins two nouns as often as two steps.
        guard lowered.range(of: #"\b(then|after|afterwards)\b"#,
                            options: .regularExpression) != nil else { return false }
        var hits = 0
        for verb in verbs {
            if lowered.range(of: #"\b"# + verb + #"\w*\b"#,
                             options: .regularExpression) != nil {
                hits += 1
                if hits >= 2 { break }
            }
        }
        guard hits >= 2 else { return false }
        // The single-step shortcut would have caught this without any model round.
        return AgentDirectIntent.parse(text) == nil
    }

    static func route(
        for text: String, role: ModelRole, cloudReady: Bool, cloudConsent: Bool
    ) -> Route {
        guard likelyMultiStep(text), role == .agent else { return .local }
        return (cloudReady && cloudConsent) ? .cloud : .localWithWarning
    }
}

/// The one honest sentence for each long-plan path. Consumer words, no tool ids,
/// no chain-of-thought — just what happens next and what it costs.
@MainActor
enum MultiStepNotices {
    static var slowWarningIssued = false

    /// "This takes a while on this Mac" — once per session, not per turn.
    static func slowWarningIfNeeded() -> String? {
        guard !slowWarningIssued else { return nil }
        slowWarningIssued = true
        return "This needs a few steps, so on this Mac it takes a few minutes. "
            + "I’ll keep going here — or connect an online model to go faster."
    }

    static func resetForTesting() { slowWarningIssued = false }

    /// "Online model — slower, leaves this Mac…" with the configured model name.
    static func cloudNotice() -> String {
        let name = ModelRoleStore.shared.displayName(for: .cloud, role: .agent)
        return "Using \(name) online — slower, and it leaves this Mac. "
            + "I’ll keep the steps on screen as I go."
    }
}

extension ModelRoleStore {
    nonisolated static func likelyMultiStep(_ text: String) -> Bool {
        MultiStepPlanRouting.likelyMultiStep(text)
    }

    typealias MultiStepRoute = MultiStepPlanRouting.Route

    nonisolated static func multiStepRoute(
        for text: String, role: ModelRole, cloudReady: Bool, cloudConsent: Bool
    ) -> MultiStepRoute {
        MultiStepPlanRouting.route(for: text, role: role, cloudReady: cloudReady, cloudConsent: cloudConsent)
    }

    static func slowWarningIfNeeded() -> String? { MultiStepNotices.slowWarningIfNeeded() }
    static func resetSlowWarningForTesting() { MultiStepNotices.resetForTesting() }
    static func cloudSlowNotice() -> String { MultiStepNotices.cloudNotice() }
}
