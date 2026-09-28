import Foundation

/// What a request is about, at the granularity tools are chosen at. Never an id.
///
/// Thirteen classes, and no more: a class is a decision about which whole family of tools
/// the planner should be *told about*, so a class that cannot change that decision does not
/// belong here. The lexicon that maps words onto these is a table, not code, so extending it
/// is a row rather than a branch — and every row added needs a fixture in
/// `--selftest-capability-manifest`, because a lexicon that is never tested is a lexicon that
/// silently stops selecting.
enum AgentIntentClass: String, CaseIterable, Sendable, Codable {
    case calendar, mail, drive, files, meetings, knowledge, reminders, memory
    case screen, browser, shell, skills, integrations

    /// The order abilities are listed in "what can you do" and in the grounding sentence.
    /// A person's own day first, then the Mac, then the past, then the things they added.
    static let spokenOrder: [AgentIntentClass] = [
        .calendar, .mail, .drive, .reminders, .meetings, .knowledge, .memory,
        .files, .screen, .browser, .shell, .skills, .integrations,
    ]
}

/// The one per-turn answer to "what may this turn do", and the only value that says so.
///
/// Four places used to answer that question and they disagreed: the planner's catalogue was
/// nine core tools plus fifteen picked by four-letter substring overlap, the rules named
/// `memory.remember` and `schedule.list` whether or not they survived that filter, the
/// grounding prose listed the full allowlist, and the execution check consulted a hard-coded
/// set of ids. So the planner could be offered a tool whose refusal path did not exist, and
/// could refuse something it had never been offered. Everything below reads this one value:
///
/// | Consumer | Reads |
/// |---|---|
/// | planner schema | `selected` |
/// | planner rule lines | `ruleLines()` |
/// | grounding prose | `groundingSurfaces`, `setupNotes` |
/// | refusal guard | `allowedIDs`, `unavailable` |
/// | execution allowlist | `entry(named:)` |
/// | "what can you do" | `capabilitiesAnswer(voice:)` |
/// | voice gates | `allowedIDs` |
///
/// There is no second roster anywhere: `plannableTools()` is a wrapper over `current()`, and
/// the builder's two id sets (`coreIDs`, `nativePlannerExclusions`) are the only literal
/// lists left in the tree, both inside `AgentCapabilityManifestBuilder`.
struct AgentCapabilityManifest: Sendable, Equatable {
    /// Which model will read the prompt. The manifest is sized for it, and a cloud reader
    /// is refused the graph and the file index without their own consent.
    struct Reader: Sendable, Equatable {
        let provider: LLMProviderID
        let displayName: String
        let contextTokens: Int
        var isCloud: Bool { provider == .openRouter }
    }

    /// Whether an enabled tool can be used right now, and — when it cannot — the one plain
    /// sentence a person would need. The sentence is for the app to say; an unavailable tool
    /// is never named in a schema.
    enum Readiness: Sendable, Equatable {
        case ready
        case needsSetup(String)
        case needsPermission(String)

        var isReady: Bool { self == .ready }
        /// The sentence, or nil when nothing is wrong.
        var reason: String? {
            switch self {
            case .ready: nil
            case .needsSetup(let sentence), .needsPermission(let sentence): sentence
            }
        }
    }

    struct Entry: Sendable, Equatable, Identifiable {
        let id: String                         // canonical registry id
        let aliases: [String]                  // registry aliases (`files.find`, `workspace.search_email`)
        let namespace: AgentToolNamespace
        let intent: AgentIntentClass
        let source: AgentToolSource
        let risk: AgentRisk
        let executionMode: AgentToolExecutionMode
        /// ≤ 160 characters, sanitized: an MCP description is third-party text.
        let modelDescription: String
        let parameters: [WorkspaceTool.Parameter]
        let readiness: Readiness
        /// "your calendar" — prose only, never an id.
        let userPhrase: String

        var isReady: Bool { readiness.isReady }

        /// Cheap enough for the conversational frontend (P3-05): a read that finishes in < 2 s.
        var frontendEligible: Bool {
            risk <= .read && executionMode == .immediate
                && [.calendar, .memory, .knowledge, .meetings, .reminders].contains(intent)
        }
    }

    let reader: Reader
    let maxRisk: AgentRisk
    /// Everything this turn may execute. Ready entries only. The execution allowlist.
    let allowed: [Entry]
    /// Enabled but not usable now (setup or permission). Named honestly in prose, never in a schema.
    let unavailable: [Entry]
    /// The entries whose schema the planner sees this turn. Whole intent classes plus the core set.
    let selected: [Entry]
    let selectedIntents: Set<AgentIntentClass>
    /// The catalogue as fitted, and how it was fitted. `selected` is a whole number of
    /// intent classes — the one thing that may never be truncated — so what the fit actually
    /// changes is how each entry is *written*, and these two record that. Without them the
    /// renderer would have to re-measure on every call to decide.
    let compactCatalogue: Bool
    let catalogueTokens: Int

    var allowedIDs: Set<String> { Set(allowed.map(\.id)) }
    var selectedIDs: Set<String> { Set(selected.map(\.id)) }
    var unavailableIDs: Set<String> { Set(unavailable.map(\.id)) }
    var frontendTools: [Entry] { allowed.filter(\.frontendEligible) }

    /// An allowed entry by canonical id or alias; nil when not allowed this turn.
    func entry(named name: String) -> Entry? {
        if let exact = allowed.first(where: { $0.id == name }) { return exact }
        return allowed.first { $0.aliases.contains(name) }
    }

    /// A copy with every allowed entry of `intent` added to `selected`.
    ///
    /// What a model earns by calling something the schema did not list: the call itself was
    /// legal, so it runs, and the next round's catalogue includes the class it reached for
    /// rather than making the same omission twice.
    func widened(toInclude intent: AgentIntentClass) -> AgentCapabilityManifest {
        let added = allowed.filter { $0.intent == intent && !selectedIDs.contains($0.id) }
        guard !added.isEmpty else { return self }
        let merged = selected + added
        return copy(selected: merged.sorted { $0.id < $1.id },
                    selectedIntents: selectedIntents.union([intent]))
    }

    /// The same turn, written for a shorter window: every selected entry's description at the
    /// compact width. Nil when nothing was left to trim, so a caller never rebuilds a
    /// manifest it did not need to rebuild.
    ///
    /// P1-05's Apple FM leg needs it because Apple's session has the shortest window anything
    /// here asks — a twelve-entry catalogue plus a persona plus a history is a lot of 4,096
    /// tokens — and the alternative to a shorter catalogue is a session the framework refuses.
    /// The same words at the same widths the prompt's own renderer uses, so there is one
    /// catalogue rendered two ways rather than two catalogues.
    func compactedForApple() -> AgentCapabilityManifest? {
        let widths = Self.compactDescriptionWidth
        let compacted = selected.map { entry in
            let description = String(entry.modelDescription.prefix(widths))
            return description == entry.modelDescription ? entry : AgentCapabilityManifest.Entry(
                id: entry.id, aliases: entry.aliases, namespace: entry.namespace,
                intent: entry.intent, source: entry.source, risk: entry.risk,
                executionMode: entry.executionMode, modelDescription: description,
                parameters: entry.parameters, readiness: entry.readiness,
                userPhrase: entry.userPhrase)
        }
        guard compacted != selected else { return nil }
        return copy(selected: compacted, selectedIntents: selectedIntents)
    }

    /// The width `renderCatalogue(compact: true)` already uses. One number, so the compacted
    /// manifest and the compacted prompt cannot be different catalogues.
    static let compactDescriptionWidth = 60

    func copy(selected: [Entry], selectedIntents: Set<AgentIntentClass>) -> AgentCapabilityManifest {
        AgentCapabilityManifest(
            reader: reader, maxRisk: maxRisk, allowed: allowed, unavailable: unavailable,
            selected: selected, selectedIntents: selectedIntents,
            compactCatalogue: compactCatalogue, catalogueTokens: catalogueTokens)
    }

    // MARK: - The "Available tools:" block

    /// `compact` = id, ≤ 60-character description, required parameter names only.
    ///
    /// Two renderings of one selected set, never two sets. The compact form is what a
    /// 4,096-token reader gets; the executor still enforces the full schema, so nothing is
    /// lost but words.
    func plannerCatalogue(compact: Bool) -> String {
        Self.renderCatalogue(selected, compact: compact)
    }

    /// The same renderer for a set that is not a manifest's `selected` yet. `build` needs it
    /// to measure a fit before it has decided one; there is no second rendering rule.
    static func renderCatalogue(_ entries: [Entry], compact: Bool) -> String {
        entries.map { entry in
            if compact {
                let required = entry.parameters.filter(\.isRequired).map(\.name)
                let tail = required.isEmpty ? "" : "; needs " + required.joined(separator: ", ")
                return "- \(entry.id): \(String(entry.modelDescription.prefix(compactDescriptionWidth)))\(tail)"
            }
            let arguments = entry.parameters.map { parameter in
                parameter.isRequired
                    ? "\(parameter.name): \(String(parameter.description.prefix(72)))"
                    : "\(parameter.name)?"
            }.joined(separator: "; ")
            return "- \(entry.id) [\(entry.risk.rawValue)]: "
                + String(entry.modelDescription.prefix(85))
                + (arguments.isEmpty ? "" : "; " + arguments)
        }.joined(separator: "\n")
    }

    /// Every spelling this turn's manifest will accept, canonical ids and aliases both.
    ///
    /// The parser needs the roster to tell a call from an explanation, and it is the same
    /// roster the executor enforces — one list, read twice, rather than a second list in the
    /// parser that could drift from the one that decides what may run.
    @MainActor
    static func callNames(_ manifest: AgentCapabilityManifest) -> Set<String> {
        var names: Set<String> = []
        for entry in manifest.allowed {
            names.insert(entry.id)
            for alias in entry.aliases { names.insert(alias) }
        }
        return names
    }

    /// The OpenAI-style `tools` array for `selected`, one entry per tool.
    ///
    /// Built from `selected` — the same list the prompt's catalogue and P1-05's grammar are
    /// built from — because a `tools` array over a *different* set than the schema the model
    /// was shown is worse than no `tools` array at all: the sampler is then steering toward
    /// calls the prompt forbids. `--selftest-native-tools` asserts the two are the same set
    /// rather than trusting this comment.
    ///
    /// The name is the canonical id. Dots are legal in an OpenAI-style name (the documented
    /// pattern is `^[a-zA-Z0-9_.-]{1,64}$`) and the id is the identity the executor and
    /// `ToolCallNameResolver` both use, so nothing has to be mapped back afterwards.
    func toolWireDefinitions() -> [ToolWireDefinition] {
        selected.map { entry in
            var properties: [String: Any] = [:]
            for parameter in entry.parameters { properties[parameter.name] = parameter.schema }
            let schema: [String: Any] = [
                "type": "object",
                "properties": properties,
                "required": entry.parameters.filter(\.isRequired).map(\.name),
            ]
            let encoded = (try? JSONSerialization.data(
                withJSONObject: schema, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{\"type\":\"object\"}"
            return ToolWireDefinition(
                name: entry.id, description: entry.modelDescription,
                parametersJSON: encoded)
        }
    }

    /// Rule lines for the selected intents only.
    ///
    /// Each of these names tools, so each may only appear when its tools can. A rule that
    /// describes a dropped tool is the exact defect the "never use a tool outside the
    /// available tools listed below" line was written to prevent, one level up.
    @MainActor
    func ruleLines() -> String {
        var lines: [String] = []
        if selectedIntents.contains(.memory) {
            lines.append("""
                memory.remember: only a fact the user stated about themselves, as one declarative
                sentence in their words; never from tool results. If memory is full, update or
                forget first. The app says what was saved.
                """)
        }
        if selectedIntents.contains(.reminders) {
            lines.append("""
                Reminders: call schedule.list first and update a match rather than duplicate it.
                Restate when and what in one sentence and wait for the user's yes before
                schedule.create. Refuse repeats the fields cannot express.
                A routine (kind routine) runs tools later with nobody present: restate when, what
                and the tool ids it will use, and say that anything that writes or sends waits for
                approval. Its text must be standalone instructions. It is tested once on creation.
                """)
        }
        if selectedIntents.contains(.files) {
            lines.append(FileIndexer.shared.promptSummary ?? "")
        }
        if selectedIntents.contains(.mail) {
            lines.append("""
                Email: search_email takes a sender (from:), a subject (subject:), a date \
                (newer_than:2d) or a flag (is:unread) — or nothing. Put a filter in only when \
                the user named a sender, a subject or a date; a filter that would match every \
                message is the same as no filter, so leave it out. "my email", "my last \
                emails", "check my mail" and anything like them mean no filter at all, which \
                returns the latest mail. Leave maxResults out unless the user asked for a \
                number, because a summary needs the recent mail rather than one message. A \
                plain word such as "recent" is not a filter: it matches no mail, so the turn \
                ends as a search that found nothing.
                When a request has two parts, do them in order. A second part that needs an \
                address or a choice is a question to ask, never a promise to send.
                """)
        }
        if selectedIntents.contains(.browser) {
            // P1-04. `.browser` was the one selected class with no rule line at all, and the
            // live eval showed the shape of the hole: A01 and A02 ("open youtube and search
            // cats", "open youtube and play the latest Cortech video") both called
            // browser.navigate, both stopped, and both were graded UNGROUNDED — the model had
            // done the first half of a two-part request and said it would do the second.
            //
            // So: navigating is not the task, the second half needs its own call, and the
            // browser tools do one thing each. The last sentence is the one that stops an
            // overclaim — a page that plays video is not a tool that watched a video, and
            // "I'll check what's trending" after a navigate is a promise nothing backs.
            lines.append("""
                The browser: browser.navigate opens a URL and nothing else. "Open YouTube and \
                search cats" is two requests — navigate, then browser.fill or browser.snapshot, \
                then click or fill to act. Never stop after the navigate and say you will look \
                for it; the turn is not finished until the second call has run. \
                browser.snapshot reads the page as text, so anything not in that text — a \
                video's contents, what is trending, what is playing — is not known, and saying \
                you will check it is a promise you cannot keep. Say what the page showed.
                """)
        }
        if selectedIntents.contains(.screen) {
            lines.append("""
                The Mac: which app is frontmost, what its window says and what is on the screen \
                come from computer.active_app, computer.windows and computer.inspect_ui. If the \
                user asks and you have not called one, you do not know: never fill the answer in \
                with a placeholder such as an app name in brackets.
                """)
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: - Prose

    /// Plain phrases for the grounding sentence, ready entries only, in a fixed order.
    var groundingSurfaces: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for intent in AgentIntentClass.spokenOrder {
            for phrase in Self.phrases(for: intent) where !seen.contains(phrase) {
                seen.insert(phrase)
                out.append(phrase)
            }
        }
        return out
    }

    /// Setup sentences for what is switched on but not usable, in the order the classes read.
    var setupNotes: [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for intent in AgentIntentClass.spokenOrder {
            for entry in unavailable where entry.intent == intent {
                guard let reason = entry.readiness.reason, !seen.contains(reason) else { continue }
                seen.insert(reason)
                out.append(reason)
            }
        }
        return out
    }

    /// Plain words for one intent class, in the order a person would say them.
    ///
    /// The only place the Agent's abilities are written in prose. `AgentGrounding.surfaces(for:)`
    /// resolves ids through this table rather than repeating it, so the grounding sentence and
    /// "what can you do" cannot drift apart.
    static func phrases(for intent: AgentIntentClass) -> [String] {
        switch intent {
        case .calendar: ["their calendar"]
        case .mail: ["their email"]
        case .drive: ["their Drive and Docs"]
        case .files: []
        case .meetings, .knowledge: ["past meetings and notes"]
        case .reminders: ["reminders and routines"]
        case .memory: ["what they tell you to remember"]
        case .screen: ["Mac apps and the screen"]
        case .browser: ["browser pages"]
        case .shell: []
        case .skills: ["installable skills"]
        case .integrations: ["the apps they have connected"]
        }
    }

    /// What this turn can do, in one line per ability. No ids, no jargon, no raw names.
    static func abilities(for intent: AgentIntentClass) -> [String] {
        switch intent {
        case .calendar: ["check your calendar"]
        case .mail: ["search and read your email"]
        case .drive: ["find and read your documents"]
        case .files: ["search your files and folders"]
        case .meetings, .knowledge: ["look through past meetings and their notes"]
        case .reminders: ["set and list your reminders"]
        case .memory: ["remember what you tell me about yourself"]
        case .screen: ["see and control Mac apps"]
        case .browser: ["open and read web pages"]
        case .shell: ["run a command on your Mac, once you approve it"]
        case .skills: ["add a new skill, once you approve it"]
        case .integrations: ["use the apps you have connected"]
        }
    }

    /// "What can you do" — typed (a short list) or voice (one or two sentences). No ids.
    ///
    /// The voice form is the ability sentence alone: `VoiceCapabilitySnapshot` qualifies it
    /// with the account state, the helper, the grant and the approval boundary, and owns
    /// those four sentences. Putting them here as well would say "Google features need
    /// connection setup" twice in one reply.
    func capabilitiesAnswer(voice: Bool) -> String {
        var ready: Set<AgentIntentClass> = []
        for entry in allowed { ready.insert(entry.intent) }
        var list: [String] = []
        for intent in AgentIntentClass.spokenOrder where ready.contains(intent) {
            list.append(contentsOf: Self.abilities(for: intent))
        }
        let notes = setupNotes
        if voice {
            guard !list.isEmpty else {
                return notes.isEmpty
                    ? "I don't have anything to look things up with yet."
                    : "Not much yet. " + notes.joined(separator: " ")
            }
            let head = list.prefix(3).map { $0 }.joined(separator: ", ")
            return "I can \(head), and more."
        }
        guard !list.isEmpty else {
            return notes.isEmpty
                ? "There is nothing I can look things up with yet."
                : "There is not much I can do yet. " + notes.joined(separator: " ")
        }
        var answer = "I can:\n" + list.map { "• " + $0 }.joined(separator: "\n")
        answer += "\nAnything that changes or sends something waits for your approval."
        if !notes.isEmpty { answer += "\n" + notes.joined(separator: " ") }
        return answer
    }
}

/// Everything the builder reads. `live(reader:)` reads the app; tests pass fixtures.
///
/// Cached state only, never a probe: a manifest is built on the path the user's turn sits on,
/// and a `gws` launch or a permission prompt in that path is a stall. `VoiceCapabilitySnapshot`
/// already publishes the same answers for the voice path, and this reads what it published.
struct AgentCapabilityInputs: Sendable {
    struct Switches: Sendable, Equatable { var memory, schedules, knowledgeTools, skills: Bool }
    struct Consent: Sendable, Equatable { var knowledgeGraphCloud, filesCloud: Bool }
    /// Registry snapshot, all sources, up to `.privileged`.
    var tools: [AgentTool]
    var switches: Switches
    var consent: Consent
    var workspace: VoiceCapabilitySnapshot.WorkspaceStatus
    /// `nil` means this process has not measured it, and unknown must not become a denial.
    var accessibilityGranted: Bool?
    var fileIndexAvailable: Bool
    var reader: AgentCapabilityManifest.Reader
    var mcpMaxRisk: AgentRisk = .send

    /// Every switch on, every grant present, a signed-in account. For a self-test whose
    /// subject is the catalogue rather than this Mac, and for the parity check: one input
    /// value, every gate open, so what the manifest answers is the roster and nothing else.
    @MainActor
    static func allEnabled(
        tools: [AgentTool], reader: AgentCapabilityManifest.Reader
    ) -> Self {
        Self(
            tools: tools,
            switches: Switches(memory: true, schedules: true, knowledgeTools: true, skills: true),
            consent: Consent(knowledgeGraphCloud: true, filesCloud: true),
            workspace: .signedIn(method: "fixture"),
            accessibilityGranted: true,
            fileIndexAvailable: true,
            reader: reader)
    }

    @MainActor
    static func live(reader: AgentCapabilityManifest.Reader) -> AgentCapabilityInputs {
        let service = AgentService.shared
        let workspace: VoiceCapabilitySnapshot.WorkspaceStatus
        if service.isProbing {
            workspace = .checking
        } else if !service.hasCachedAuthStatus {
            workspace = .unknown
        } else {
            workspace = VoiceCapabilitySnapshot.WorkspaceStatus.cached(service.authState, isProbing: false)
        }
        return AgentCapabilityInputs(
            tools: AgentToolRegistry.shared.tools(upTo: .privileged),
            switches: Switches(
                memory: MemorySnapshotCache.shared.isEnabled,
                schedules: Settings.shared.agentSchedulesEnabled,
                knowledgeTools: KnowledgeToolGate.isAvailable,
                skills: SkillToolGate.isAvailable),
            consent: Consent(
                knowledgeGraphCloud: Settings.shared.knowledgeGraphCloudConsent,
                filesCloud: UserDefaults.standard.bool(forKey: IndexedFoldersStore.cloudConsentKey)),
            workspace: workspace,
            accessibilityGranted: Permissions.hasAccessibility,
            fileIndexAvailable: LiveFileRetrieval().isAvailable,
            reader: reader)
    }
}

enum AgentCapabilityManifestBuilder {
    /// Native registry tools the planner has never been offered. Preserves today's behaviour
    /// exactly (the old 63-id allowlist minus these == the old 63); widening it is a separate
    /// decision measured by `--selftest-toolloop-live`, not a side effect of this task.
    ///
    /// Verified on 2026-09-26 against `AgentToolRegistry.shared.tools(upTo: .send)`: the set is
    /// that list minus the allowlist `--selftest-capability-manifest` pins, and every id here is
    /// genuinely registered. `filesystem.delete` and `browser.purchase` are not listed because
    /// the `.send` ceiling already excludes them — the two lists are the same fact, and only
    /// one of them is written down. The ACP and Codex-handoff tools are not listed either: they
    /// are never registered (a local `AgentTool` value, or `.privileged`), so naming them here
    /// would be a claim about ids that do not exist.
    static let nativePlannerExclusions: Set<String> = [
        "computer.scroll", "computer.drag", "computer.double_click", "computer.right_click",
        "computer.wait_for", "shell.status", "shell.cancel", "browser.download",
        "browser.cdp_status", "browser.relaunch_debug", "browser.read_page", "browser.wait",
    ]

    /// Always selected (today's `coreToolIDs`), when allowed.
    ///
    /// The floor for a turn that named no class at all, so it is deliberately narrow: a core
    /// id is in **every** turn's schema whatever the turn is about, so an id here is a tool
    /// offered to a question it has nothing to do with. `search_email` was one until
    /// 2026-09-26, and the live eval measured what that costs — a YouTube request called
    /// `search_email(query: "Cortech latest video")` beside `browser.navigate`, and "what did
    /// Sarah say about the budget" called `search_email(query: "from:sarah subject:budget")`
    /// and leaked the call as its answer. Mail is a whole class the lexicon selects, from
    /// "email", "mail", "inbox", "gmail", "unread", "sender", "reply", "draft" or a newsletter,
    /// and a class that is selected is selected whole — so nothing about mail is lost by
    /// taking the id out of the floor. Nothing is lost from `allowed` either: `coreIDs` decides
    /// what the model is *shown*, and the execution allowlist, the refusal guard, "what can
    /// you do" and the direct-intent shortcut all read `allowed`, which is the parity set.
    static let coreIDs: Set<String> = [
        "get_agenda", "filesystem.search", "filesystem.find", "filesystem.tree",
        "filesystem.reveal", "computer.active_app", "computer.open_app", "browser.navigate",
    ]

    /// The two tools that read the indexed folders rather than the disk.
    static let fileIndexToolIDs: Set<String> = [FileToolCatalogue.findID, FileToolCatalogue.treeID]

    /// The tools that read the indexed folders rather than the disk, and the two graph reads.
    static let cloudRestrictedIDs: Set<String> = [
        FileToolCatalogue.findID, FileToolCatalogue.treeID, "expand_node", "timeline",
    ]

    /// Tokens the catalogue may spend, by reader. A 4,096-token window is Apple's floor and the
    /// worst case a manifest is ever fitted for; a local GGUF has room for more.
    static func catalogueBudget(for reader: AgentCapabilityManifest.Reader) -> Int {
        reader.contextTokens <= 4_096 ? 700 : 1_600
    }

    /// P1-01's `RealtimeAgent.toolGatesForTesting`, replaced: a self-test hands the builder an
    /// `AgentCapabilityInputs` instead of four booleans, which is what lets a fixture carry
    /// consent, readiness and a reader as well as the switches. Nil in production, and read
    /// only under `SelfTest.isRunning`, so a stray assignment cannot change a real turn's
    /// roster.
    @MainActor
    static var inputsOverrideForTesting: AgentCapabilityInputs?

    /// Characters per token, the same estimate the budget's own fallback uses.
    static let charactersPerToken = 4

    static func estimatedTokens(_ text: String) -> Int {
        (text.count + charactersPerToken - 1) / charactersPerToken
    }

    // MARK: - Intent

    /// The class a tool belongs to. By namespace, then by id for Workspace.
    static func intent(for tool: AgentTool) -> AgentIntentClass {
        switch tool.namespace {
        case .workspace:
            switch tool.id {
            case "get_agenda", "create_event": return .calendar
            case "search_email", "draft_email", "send_email", "reply_email", "read_email":
                return .mail
            case "find_drive_files", "read_doc", "create_doc", "append_doc", "upload_to_drive":
                return .drive
            default: return .drive
            }
        case .meeting: return .meetings
        case .knowledge: return .knowledge
        case .schedule: return .reminders
        case .memory: return .memory
        case .filesystem: return .files
        case .computer: return .screen
        case .browser: return .browser
        case .shell: return .shell
        case .skills: return .skills
        case .github, .notion, .slack, .mcp: return .integrations
        }
    }

    /// A deterministic lexicon. Extend the table; remove a row only when a word has been
    /// measured selecting a class it does not mean. Every row added needs a fixture in
    /// `--selftest-capability-manifest`, because a lexicon that is never tested is a lexicon
    /// that silently stops selecting — and every row removed needs one too, since a word that
    /// stops selecting is as silent as one that never did.
    ///
    /// Word-bounded alternatives, applied to the lowercased request after "to-do"/"e-mail" are
    /// normalised. A miss is not fatal — the allowlist still executes any allowed tool and a
    /// wrong-class call widens the next round — but a miss costs a narrower schema, so the
    /// table is where the eval's `MISSED_TOOL` rows get answered. A *hit* that means nothing
    /// is worse than a miss: it widens the schema for a turn the word never described, which
    /// is how a browser request was handed `computer.open_url`. So a word that two classes
    /// both use does not go in the table; `namesKnownApp` is how the screen class is reached
    /// by a name rather than by a verb.
    static let lexicon: [AgentIntentClass: [String]] = [
        .calendar: [
            "calendar", "calendars", "agenda", "event", "events", "booked", "busy",
            "am i free", "what do i have", "free at",
            // "schedule" means a reminder when a reminder is what is being asked for, and
            // the negative lookahead is how one word means two different capabilities.
            "schedul(e|ed|ing)?(?!\\s+(a|an|me|my|it|them)?\\s*(reminder|reminders|task|tasks|to\\b|to-do))",
            "meetings?\\s+(today|tomorrow|this week|next)",
        ],
        .mail: [
            "e?mails?", "inbox", "gmail", "unread", "messages? from", "sender", "senders",
            "repl(y|ied|ies)", "draft", "drafts", "newsletter",
        ],
        .drive: ["drive", "google docs?", "sheets?", "slides?", "shared with me"],
        .files: [
            "files?", "folders?", "documents?", "docs?", "pdf", "projects?",
            "desktop", "downloads", "repo", "repos", "repository", "repositories",
        ],
        .meetings: [
            "meetings?", "call (with|yesterday|earlier)", "calls (with|yesterday|earlier)",
            "transcript", "transcripts", "action items?", "decid(e|ed|es|ing)", "decision",
            "decisions", "[a-z']+ said", "minutes",
        ],
        .knowledge: [
            "what did (we|i|they)", "last time", "remind me what", "notes? (about|from|on)",
            "history", "(summari[sz]e|everything).*(know|about me)", "did we say",
        ],
        .reminders: [
            "remind", "reminds", "reminder", "reminders", "reminding", "todo", "to do list",
            "to-do", "tasks?", "routine", "routines",
            "every (day|night|morning|evening|week|weekend|monday|tuesday|wednesday|thursday|friday|saturday|sunday)",
            "alarm", "alarms",
        ],
        .memory: [
            "remember", "remembers", "forget", "forgets", "about me", "who am i",
            "my (name|brother|sister|wife|husband|partner|job|email address)",
        ],
        .screen: [
            // No bare "open". It introduces a site ("open youtube"), an app ("open Slack")
            // and a file ("open the pricing document") equally, so on its own it selected
            // the whole screen class for almost every request — and `computer.open_url` then
            // won a YouTube request from `browser.navigate` (A02, WRONG_TOOL, 2026-09-26).
            // P1-13's own lesson applies to a table: a word that means two capabilities is
            // not evidence of either. An app named by name is the evidence, and that is
            // `namesKnownApp` below rather than a second list of app names here.
            "launch", "click", "type", "press", "app", "apps",
            "application", "applications", "window", "windows", "frontmost", "screen",
            "screens", "quit", "menus?", "buttons?",
        ],
        .browser: [
            "website", "web sites?", "web ?pages?", "page", "pages", "url", "browser",
            "chrome", "safari", "youtube", "google (it|for)", "search (the web|online|for)",
        ],
        .shell: ["terminal", "shell", "command line", "run the command", "run a command"],
        .skills: ["skill", "skills"],
    ]

    /// What the request is about. `toolNames` adds the connected-app class: a registered MCP
    /// server's own name, and any word of four letters or more in an MCP tool's name.
    static func intents(in request: String, toolNames: [String] = []) -> Set<AgentIntentClass> {
        let text = normalized(request)
        guard !text.isEmpty else { return [] }
        var matched: Set<AgentIntentClass> = []
        for (intent, alternatives) in lexicon {
            if alternatives.contains(where: { matches(text, $0) }) { matched.insert(intent) }
        }
        if namesKnownApp(text) { matched.insert(.screen) }
        if looksLikeURL(text) { matched.insert(.browser) }
        if mentionsConnectedApp(text, toolNames: toolNames) { matched.insert(.integrations) }
        return matched
    }

    /// Whether the sentence asks to open a named application — the signal the bare verb
    /// "open" used to be.
    ///
    /// `AgentDirectIntent` holds the only list of app names in the tree and already decides
    /// "this sentence opens an app rather than a page", so this asks it rather than keeping a
    /// second copy of the names that could disagree. A page beside the app still counts
    /// ("open Chrome and go to youtube.com" is a screen request as well as a browser one); a
    /// page on its own does not ("open youtube and play the latest Cortech video"), which is
    /// the half that was wrong.
    ///
    /// Asked with the shortcut's looser sentence rule, because this is a narrower question:
    /// not "is this whole sentence one open action" but "does it name an app to open", so a
    /// second step in the sentence does not hide the app behind it.
    private static func namesKnownApp(_ text: String) -> Bool {
        switch AgentDirectIntent.parse(text, wholeSentence: false) {
        case .openApp: return true
        case .openURL(_, let app): return app != nil
        case .locate, .none: return false
        }
    }

    /// The two spellings that would otherwise be missed, applied before the table runs.
    static func normalized(_ request: String) -> String {
        var text = request.lowercased()
        for (from, to) in [("to-do", "todo"), ("to do", "todo"), ("e-mail", "email")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        return text
    }

    /// Whether the lowercased request contains one lexicon alternative as a whole word.
    private static func matches(_ text: String, _ alternative: String) -> Bool {
        guard let regex = bounded(alternative) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Word boundaries around one alternative, without doubling a boundary it already carries.
    private static func bounded(_ alternative: String) -> NSRegularExpression? {
        // Built once per call site in practice: the table is small and this runs on a
        // background-free path, so a cache would be noise. `NSRegularExpression` is the
        // system's, so `\b` means what the rest of the tree's regexes mean by it.
        let core = alternative.hasSuffix("\\b") ? String(alternative.dropLast(2)) : alternative
        let pattern = "\\b(?:" + core + ")\\b"
        // A malformed alternative is a typo in the table, not a reason to answer wrongly:
        // fall back to a pattern that matches nothing.
        return try? NSRegularExpression(pattern: pattern)
    }

    private static func looksLikeURL(_ text: String) -> Bool {
        if text.contains("www.") { return true }
        guard let regex = try? NSRegularExpression(
            pattern: "\\b[a-z0-9-]+\\.(com|org|net|io|co|dev|app|ai|edu|gov)\\b") else {
            return false
        }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func mentionsConnectedApp(_ text: String, toolNames: [String]) -> Bool {
        for name in ["github", "slack", "notion", "linear", "jira"] where text.contains(name) {
            return true
        }
        guard !toolNames.isEmpty else { return false }
        for name in toolNames {
            for word in name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                guard word.count >= 4 else { continue }
                if matches(text, String(word)) { return true }
            }
        }
        return false
    }

    // MARK: - Build

    static func build(
        _ inputs: AgentCapabilityInputs, request: String,
        previousRequest: String? = nil, maxRisk: AgentRisk = .send
    ) -> AgentCapabilityManifest {
        let candidates = admitted(inputs, maxRisk: maxRisk)
        let ready = candidates.filter { $0.readiness.isReady }
        let unavailable = candidates.filter { !$0.readiness.isReady }

        var matched = intents(in: request, toolNames: toolNames(inputs.tools))
        // A short or anaphoric turn ("those", "yes", "do it") says nothing about capability on
        // its own; the previous request is what it means. `previousRequest` is the earlier turn
        // the caller passed, never the same string again.
        if matched.isEmpty || isShortOrAnaphoric(request) {
            if let previousRequest {
                matched.formUnion(intents(in: previousRequest, toolNames: toolNames(inputs.tools)))
            }
        }
        // A question about what was decided and a question about the past are the same
        // question asked two ways, and the tools that answer them are the same tools.
        if matched.contains(.knowledge) { matched.insert(.meetings) }
        if matched.contains(.meetings) { matched.insert(.knowledge) }

        let core = ready.filter { coreIDs.contains($0.id) }
        let chosen = ready.filter { matched.contains($0.intent) }
        var selected = dedupe(core + chosen).sorted { $0.id < $1.id }
        // The classes this turn was *asked about*, which is not the same as the classes the
        // core set happens to touch: `coreIDs` is a handful of ids, and a class reaching the
        // schema because one of its members is a core id says nothing about the request. A
        // matched class is whole; an unmatched class is not, and `ruleLines()` reads this
        // rather than guessing from the ids.
        let intents = matched

        let budget = catalogueBudget(for: inputs.reader)
        var compact = false
        var estimate = estimatedTokens(catalogue(selected, compact: false))
        if estimate > budget {
            compact = true
            estimate = estimatedTokens(catalogue(selected, compact: true))
        }
        if estimate > budget {
            // Core entries whose class the request did not match go first: they are a floor
            // for a request that named nothing, not an answer to one that did. A matched class
            // is never truncated — P1-10's per-round token check handles the overflow instead.
            let trimmed = selected.filter { matched.contains($0.intent) || coreIDs.contains($0.id) }
            let droppedCore = selected.filter { !trimmed.contains($0) && coreIDs.contains($0.id) }
            if !droppedCore.isEmpty {
                selected = trimmed
                estimate = estimatedTokens(catalogue(selected, compact: true))
                if estimate > budget {
                    Log.agent.info("manifest over budget: \(estimate) tokens")
                }
            }
        }
        return AgentCapabilityManifest(
            reader: inputs.reader, maxRisk: maxRisk,
            allowed: ready, unavailable: unavailable, selected: selected,
            selectedIntents: intents, compactCatalogue: compact, catalogueTokens: estimate)
    }

    private static func catalogue(
        _ entries: [AgentCapabilityManifest.Entry], compact: Bool
    ) -> String {
        AgentCapabilityManifest.renderCatalogue(entries, compact: compact)
    }

    private static func dedupe(_ entries: [AgentCapabilityManifest.Entry]) -> [AgentCapabilityManifest.Entry] {
        var seen: Set<String> = []
        return entries.filter { seen.insert($0.id).inserted }
    }

    /// Whether a turn says nothing about capability on its own. Short is one test; anaphora is
    /// the other, and the words are matched whole so "what is it about" is not a pronoun —
    /// reading it as one would union the previous turn's classes into a question that named
    /// its own, which is a wider schema than the request asked for.
    static let anaphors = [
        "those", "them", "it", "that one", "the last one", "yes", "do it", "go on", "again",
    ]
    private static func isShortOrAnaphoric(_ request: String) -> Bool {
        let text = request.lowercased()
        if text.split(whereSeparator: \.isWhitespace).count <= 6 { return true }
        return anaphors.contains { matches(text, $0) }
    }

    private static func toolNames(_ tools: [AgentTool]) -> [String] {
        tools.filter { $0.source == .mcp || $0.source == .composio }.map(\.id)
    }

    // MARK: - The filters, in the order they are written down

    /// Every tool this turn could use, with its readiness decided. Two lists out of one pass:
    /// ready and not-yet.
    private static func admitted(
        _ inputs: AgentCapabilityInputs, maxRisk: AgentRisk
    ) -> [AgentCapabilityManifest.Entry] {
        var entries: [AgentCapabilityManifest.Entry] = []
        let natives = inputs.tools.filter { $0.source == .native }
        let nativeIDs = Set(natives.map(\.id))
        let nativeNames = Set(natives.map { $0.name.lowercased() })
        for tool in inputs.tools where tool.risk <= maxRisk {
            switch tool.source {
            case .native:
                if nativePlannerExclusions.contains(tool.id) { continue }
            case .mcp, .composio:
                // Third-party text never enters the planner above `.send`, and never shadows
                // a native implementation of the same capability. "Same capability" is the
                // tool's *name*: an MCP Gmail search arrives as `workspace.search_email`, and
                // the id comparison alone would let it through beside the native one.
                if tool.risk > inputs.mcpMaxRisk { continue }
                if nativeIDs.contains(tool.id) { continue }
                if nativeNames.contains(tool.name.lowercased()) { continue }
            case .acp:
                continue
            }
            guard passes(tool, inputs) else { continue }
            entries.append(entry(for: tool, inputs: inputs))
        }
        return entries.sorted { $0.id < $1.id }
    }

    /// The four switches and the two consents. Mirrors today's gates exactly; the knowledge
    /// pair is `KnowledgeToolGate.isAvailable` read as it stands, so P1-17 changes the rule in
    /// one place rather than in a second copy here.
    private static func passes(_ tool: AgentTool, _ inputs: AgentCapabilityInputs) -> Bool {
        switch tool.namespace {
        case .memory: guard inputs.switches.memory else { return false }
        case .schedule: guard inputs.switches.schedules else { return false }
        case .knowledge: guard inputs.switches.knowledgeTools else { return false }
        case .skills: guard inputs.switches.skills else { return false }
        default: break
        }
        if inputs.reader.isCloud {
            if cloudRestrictedIDs.contains(tool.id) {
                if tool.id == "expand_node" || tool.id == "timeline" {
                    guard inputs.consent.knowledgeGraphCloud else { return false }
                } else {
                    guard inputs.consent.filesCloud else { return false }
                }
            }
        }
        return true
    }

    /// Cached state only. Nothing here launches a process, prompts for a permission, or waits.
    private static func entry(
        for tool: AgentTool, inputs: AgentCapabilityInputs
    ) -> AgentCapabilityManifest.Entry {
        makeEntry(for: tool, readiness: readiness(for: tool, inputs: inputs))
    }

    /// One entry for one tool with nothing to wait for. What a caller holding a roster of ids
    /// rather than a set of inputs needs — the refusal guard's id-set entry point — and what
    /// keeps the alias, intent and description rules in one place for it to inherit.
    static func readyEntry(for tool: AgentTool) -> AgentCapabilityManifest.Entry {
        makeEntry(for: tool, readiness: .ready)
    }

    private static func makeEntry(
        for tool: AgentTool, readiness: AgentCapabilityManifest.Readiness
    ) -> AgentCapabilityManifest.Entry {
        let source = tool.source
        return AgentCapabilityManifest.Entry(
            id: tool.id,
            aliases: aliases(for: tool),
            namespace: tool.namespace,
            intent: intent(for: tool),
            source: source,
            risk: tool.risk,
            executionMode: tool.executionMode,
            modelDescription: description(for: tool, source: source),
            parameters: tool.parameters,
            readiness: readiness,
            userPhrase: userPhrase(for: intent(for: tool)))
    }

    /// The spellings the registry resolves to this tool. The canonical id is never repeated
    /// here: `entry(named:)` checks it first.
    static func aliases(for tool: AgentTool) -> [String] {
        var out: [String] = []
        if tool.namespace != .workspace {
            out.append("\(tool.namespace.rawValue).\(tool.name)")
        } else {
            out.append("workspace.\(tool.name)")
        }
        if tool.namespace == .filesystem,
           FileToolCatalogue.aliasIDs.contains(tool.name) {
            out.append("files.\(tool.name)")
        }
        if tool.source == .mcp || tool.source == .composio {
            out.append("mcp.\(tool.name)")
        }
        return out.filter { $0 != tool.id }
    }

    /// Third-party text, sanitized. An MCP description is written by a stranger and is read
    /// by a model that will also be asked to call it, so the shape a prompt line may not
    /// have — angle brackets, backticks, newlines — is removed rather than trusted.
    static func sanitize(_ text: String, cap: Int = 160) -> String {
        var out = text
        for character in ["<", ">", "`", "\n", "\r", "\t"] {
            out = out.replacingOccurrences(of: character, with: " ")
        }
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(out.prefix(cap))
    }

    private static func description(for tool: AgentTool, source: AgentToolSource) -> String {
        let sanitized = sanitize(tool.description)
        switch source {
        case .mcp, .composio: return "(connected app) " + String(sanitized.prefix(140))
        case .native, .acp: return sanitized
        }
    }

    static func userPhrase(for intent: AgentIntentClass) -> String {
        AgentCapabilityManifest.phrases(for: intent).first ?? "this Mac"
    }

    private static func readiness(
        for tool: AgentTool, inputs: AgentCapabilityInputs
    ) -> AgentCapabilityManifest.Readiness {
        switch tool.namespace {
        case .workspace:
            switch inputs.workspace {
            case .signedIn, .unknown, .checking: return .ready
            case .notInstalled, .needsOAuthClient, .signedOut, .failed:
                return .needsSetup(InputsText.workspaceSetup)
            }
        case .computer:
            if accessibilityTools.contains(tool.id), inputs.accessibilityGranted == false {
                return .needsPermission(InputsText.accessibilitySetup)
            }
        case .filesystem:
            if fileIndexToolIDs.contains(tool.id), !inputs.fileIndexAvailable {
                return .needsSetup(InputsText.fileIndexSetup)
            }
        default:
            break
        }
        // A cloud reader's own consent is the gate above, not a second statement of it here:
        // two copies of one rule is the drift this file exists to remove, and a tool that was
        // admitted is ready by definition.
        return .ready
    }

    /// The computer tools that need the Accessibility grant, from the task's list.
    static let accessibilityTools: Set<String> = [
        "computer.click", "computer.type", "computer.press_key", "computer.set_text",
        "computer.inspect_ui", "computer.focus", "computer.get_selection",
    ]

    /// One sentence per missing thing, in a person's words. They reach the app's own prose —
    /// the grounding sentence and "what can you do" — never a prompt's tool list, and they
    /// name no id.
    enum InputsText {
        static let workspaceSetup =
            "Email, calendar and Drive need Google connected in Settings ▸ Workspace."
        static let accessibilitySetup =
            "Working with apps needs Accessibility for this app in System Settings ▸ Privacy."
        static let fileIndexSetup =
            "Add a folder in Settings ▸ Files so I can search it."
        static let graphConsent =
            "An online model may not read the life map. Allow that in Settings ▸ Knowledge."
        static let filesConsent =
            "An online model may not see your folder and file names. Allow that in Settings ▸ Knowledge."
    }
}

extension AgentCapabilityManifest.Reader {
    /// The conversational frontend's reader: Apple's on-device model, whose window the
    /// provider itself reports (4,096 on the first generation, 8,192 measured since).
    static let voiceFrontend = AgentCapabilityManifest.Reader(
        provider: .appleFoundation, displayName: "Apple",
        contextTokens: FoundationModelLLMProvider().contextTokens)

    /// The reader bound to the turn in flight. `runPlannedTurn` publishes the provider it
    /// resolved, so the refusal guard, the grounding and the voice gates size themselves for
    /// the model that will actually see the prompt rather than for a guess.
    ///
    /// Falls back to the app's own runtime when nothing has published — a voice gate asked
    /// outside a turn, for instance.
    @MainActor static var agentRole: AgentCapabilityManifest.Reader {
        if let published = AgentCapabilityManifestRuntime.publishedReader { return published }
        // The same read `LLMProviders.make` does for `.appLLM`, so the fallback names the file
        // the runtime will load rather than the built-in that shipped this release.
        let provider = LlamaLLMProvider(modelName: InstalledModelLibrary.shared.activeModel?.displayName)
        return AgentCapabilityManifest.Reader(
            provider: provider.id, displayName: provider.displayModelName,
            contextTokens: provider.contextTokens)
    }
}

/// The per-turn state a manifest cannot carry in itself: which reader the turn resolved, and
/// the one cache every out-of-turn reader shares.
///
/// `current()` is called from the grounding publish, the voice gates, the refusal guard and
/// the direct-intent shortcut — none of which may pay for a registry walk on a user's turn,
/// and none of which can await. So the build is cached by a fingerprint of everything it
/// reads, and a turn that changes one of them gets a new value on the next call. The
/// fingerprint is the cache key *and* the invalidation: a reader built from a stale key would
/// be a second roster, which is the thing this whole type exists to prevent.
/// The last manifest any build produced, for the readers that run without the main actor.
///
/// A lock rather than an actor for the same reason `AgentGroundingCache` and
/// `MemorySnapshotCache` are: the prompt builders are `nonisolated` and cannot await, and the
/// facts they need are the ones a build already decided. It holds prose, not ids, so the
/// reader needs neither the registry nor an actor to render it.
final class AgentCapabilityMirror: @unchecked Sendable {
    static let shared = AgentCapabilityMirror()

    private let lock = NSLock()
    private var manifest: AgentCapabilityManifest?

    func publish(_ value: AgentCapabilityManifest) {
        lock.lock()
        defer { lock.unlock() }
        manifest = value
    }

    /// Empty before anything has been built: a prompt that has not asked may say nothing
    /// about what is reachable, and must never claim a capability nobody has confirmed.
    var current: AgentCapabilityManifest? {
        lock.lock()
        defer { lock.unlock() }
        return manifest
    }
}

@MainActor
enum AgentCapabilityManifestRuntime {
    /// Published by `runPlannedTurn` immediately after its single provider resolution.
    static var publishedReader: AgentCapabilityManifest.Reader?

    private struct CacheKey: Equatable {
        let switches: AgentCapabilityInputs.Switches
        let consent: AgentCapabilityInputs.Consent
        let workspace: VoiceCapabilitySnapshot.WorkspaceStatus
        let accessibilityGranted: Bool?
        let fileIndexAvailable: Bool
        let registryCount: Int
        let reader: AgentCapabilityManifest.Reader
    }

    private static var cachedKey: CacheKey?
    private static var cachedManifest: AgentCapabilityManifest?

    static func publish(_ manifest: AgentCapabilityManifest) {
        AgentCapabilityMirror.shared.publish(manifest)
    }

    /// The manifest for a reader, from the app's own state. Cached by fingerprint; the
    /// registry walk and the two `UserDefaults` reads happen only when something moved.
    static func current(reader: AgentCapabilityManifest.Reader) -> AgentCapabilityManifest {
        if let override = AgentCapabilityManifestBuilder.inputsOverrideForTesting, SelfTest.isRunning {
            return override.manifest(request: "")
        }
        let live = AgentCapabilityInputs.live(reader: reader)
        let key = CacheKey(
            switches: live.switches, consent: live.consent, workspace: live.workspace,
            accessibilityGranted: live.accessibilityGranted,
            fileIndexAvailable: live.fileIndexAvailable,
            registryCount: live.tools.count, reader: live.reader)
        if let cachedKey, cachedKey == key, let cachedManifest { return cachedManifest }
        let manifest = AgentCapabilityManifestBuilder.build(live, request: "")
        cachedKey = key
        cachedManifest = manifest
        publish(manifest)
        return manifest
    }

    /// A test that needs a manifest with a particular reader to go through the same cache.
}

extension AgentCapabilityManifest {
    /// The manifest for this reader, right now, from the app's own state. What every caller
    /// outside a planner turn reads: the grounding publish, the voice gates, the refusal
    /// guard, the direct-intent shortcut. A turn builds its own with the request in hand and
    /// never comes here — the ranking is per request, and an empty one is the wrong answer
    /// to "what's on my calendar".
    @MainActor
    static func current(reader: AgentCapabilityManifest.Reader = .agentRole) -> AgentCapabilityManifest {
        AgentCapabilityManifestRuntime.current(reader: reader)
    }
}

extension AgentCapabilityInputs {
    /// The manifest these inputs describe. Named so the override above reads as what it is:
    /// inputs in, one manifest out.
    func manifest(request: String) -> AgentCapabilityManifest {
        AgentCapabilityManifestBuilder.build(self, request: request)
    }
}
