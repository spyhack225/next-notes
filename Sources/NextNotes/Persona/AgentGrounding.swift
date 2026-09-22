import Foundation

/// Who the person is, what the assistant is called, and what it can actually reach.
///
/// This exists because those three facts lived in four stores with four different
/// isolations, and the paths that needed them most carried none of them. On 2026-09-20 the
/// conversation log recorded "I don't know what you are working on. I need to check your
/// files and history to find out." and, a minute later, "I cannot open the 'next project'
/// folder" — with 8,796 files indexed from Desktop, Documents and Downloads and both file
/// tools registered and allowed. The first-pass prompt
/// (`RealtimeAgent.voiceRoutingSystem`) carried the persona and an empty memory section and
/// nothing else: no name, no folder list, no tool roster. So the model answered honestly
/// from what it had been told, which was nothing.
///
/// Everything here is read without the main actor, because the prompt builders run on the
/// Foundation Models frontend actor and in `nonisolated` statics. The facts that can be read
/// from disk or `UserDefaults` are read there; the two that cannot — the row count and the
/// live planner roster — are published into `AgentGroundingCache` by the main-actor entry
/// points that already run before every prompt is assembled, and have honest fallbacks when
/// nothing has published yet.
struct AgentGrounding: Sendable, Equatable {
    /// What the assistant is called — `agent-identity.json`, the same name the island shows.
    var assistantName: String
    /// The account holder's name on this Mac.
    var userFullName: String
    /// Folders the user shared, by last path component. Empty when the switch is off, when
    /// no folder is listed, or when a cloud reader has no consent to hear the names.
    var folders: [String]
    /// Rows in the file index. Zero means "not published yet" and the sentence omits it
    /// rather than claiming a number nobody counted.
    var indexedItems: Int
    /// Reachable surfaces in plain words, already filtered to what is registered and allowed.
    var surfaces: [String]

    /// The header every rendering starts with. Self-tests look for this exact line.
    static let header = "About this Mac and the person using it (device facts, not guesses):"

    /// The one instruction in the block. It is a floor, not a licence: it forbids a denial
    /// the lines above contradict, and it never authorises an action.
    ///
    /// The clause about files is conditional because the rule has to stay true. With folder
    /// access switched off, "never say you cannot reach their files" would be the prompt
    /// telling the model to claim something it cannot do — the same fault as the refusals
    /// this block exists to stop, pointed the other way.
    static func denialRule(hasFolders: Bool) -> String {
        var rule = "Never say you do not know who this person is"
        rule += hasFolders ? ", and never say you cannot reach their files or folders." : "."
        rule += " When you need a name, a path or a date you do not have, look it up with a "
            + "tool instead of refusing."
        return rule
    }

    /// First name, for the "call them X" clause. Falls back to the full name.
    var userShortName: String {
        userFullName.split(separator: " ").first.map(String.init) ?? userFullName
    }

    var hasUser: Bool { !userFullName.isEmpty }

    /// The block as a prompt section, or empty when there is nothing truthful to say.
    ///
    /// - Parameter compact: the Apple Foundation Models voice path has 4,096 tokens for the
    ///   whole turn, so it gets the same facts without the tool ids.
    func text(compact: Bool) -> String {
        var lines: [String] = []
        var identity: [String] = []
        if !assistantName.isEmpty { identity.append("You are \(assistantName).") }
        if hasUser {
            identity.append(userShortName == userFullName
                ? "You are talking with \(userFullName)."
                : "You are talking with \(userFullName) — call them \(userShortName).")
        }
        if !identity.isEmpty { lines.append(identity.joined(separator: " ")) }
        if let reach = reachLine(compact: compact) { lines.append(reach) }
        guard !lines.isEmpty else { return "" }
        return ([Self.header] + lines + [Self.denialRule(hasFolders: !folders.isEmpty)])
            .joined(separator: "\n")
    }

    /// The lead-in. It says *with a tool*, in as many words, because the list on its own
    /// reads to a small model like knowledge it already has: on the first run of
    /// `--selftest-tool-awareness` with this block in place, "What is on my to-do list for
    /// today?" came back `<answer/>` instead of `<use_tools/>`.
    static let reachPrefix = "You can reach all of these, but only by calling a tool for them — never from memory:"

    /// One sentence, the folders last because they carry the tool names.
    ///
    /// No parentheses around a tool id: `FileIndexer.advertisedToolNames` reads any dotted
    /// word as a tool name and trims only `.;:`, so "filesystem.tree)" read as a tool the
    /// planner cannot call. The check is right and the sentence was wrong.
    func reachLine(compact: Bool) -> String? {
        var parts = surfaces
        if !folders.isEmpty {
            let names = ListFormatter.localizedString(byJoining: folders)
            var clause = "their \(names)"
            if indexedItems > 0 {
                clause += " — \(indexedItems.formatted()) indexed files and folders"
            }
            if !compact {
                clause += ", searched by name with \(FileToolCatalogue.findID)"
                    + " and listed with \(FileToolCatalogue.treeID)"
            }
            parts.append(clause)
        }
        guard !parts.isEmpty else { return nil }
        return Self.reachPrefix + " " + parts.joined(separator: ", ") + "."
    }

    // MARK: - Reading the facts

    /// The live grounding for this process, for the reader bound to this turn.
    ///
    /// - Parameter reader: a cloud model hears no folder names without the user's consent,
    ///   the same rule `FileIndexer.promptSummary` and the file tools already apply.
    static func current(
        reader: LLMProviderID? = KnowledgeGraphScope.reader,
        cache: AgentGroundingCache = .shared,
        defaults: UserDefaults = .standard
    ) -> Self {
        let published = cache.snapshot()
        let mayReadFiles = FileIndexScope.mayRead(
            reader: reader,
            cloudConsent: defaults.bool(forKey: IndexedFoldersStore.cloudConsentKey)
        )
        let filesOn = defaults.object(forKey: IndexedFoldersStore.enabledKey) as? Bool ?? false
        let folders = (mayReadFiles && filesOn) ? published.folders : []
        return Self(
            assistantName: AgentGroundingFacts.assistantName(),
            userFullName: AgentGroundingFacts.userFullName(),
            folders: folders,
            indexedItems: folders.isEmpty ? 0 : published.indexedItems,
            surfaces: surfaces(for: published.toolIDs)
        )
    }

    /// Plain words for the tool ids, in the order a person would say them. Nothing is named
    /// that the planner is not allowed to call, so the sentence can never promise a tool the
    /// next pass would refuse.
    static func surfaces(for ids: Set<String>) -> [String] {
        var names: [String] = []
        if ids.contains("get_agenda") || ids.contains("create_event") { names.append("their calendar") }
        if ids.contains("search_email") { names.append("their email") }
        if ids.contains("find_drive_files") || ids.contains("read_doc") { names.append("their Drive and Docs") }
        if ids.contains("computer.open_app") || ids.contains("computer.click") {
            names.append("Mac apps and the screen")
        }
        if ids.contains("browser.navigate") { names.append("browser pages") }
        if ids.contains("meeting.transcript") || ids.contains("search_knowledge") {
            names.append("past meetings and notes")
        }
        if ids.contains("schedule.create") { names.append("reminders and routines") }
        if ids.contains("memory.remember") { names.append("what they tell you to remember") }
        if ids.contains("skills.search") { names.append("installable skills") }
        return names
    }
}

/// Facts that can be read without the main actor: the assistant's own name and the account
/// holder's. Both are cheap — one `stat` and one `getpwuid` — so no session freeze is needed
/// and a rename in Settings is heard on the next turn.
enum AgentGroundingFacts {
    private struct Cached: Sendable {
        var name: String
        var modified: Date?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var identity: Cached?

    /// Spelled out rather than read from `AgentIdentityStore`, whose statics belong to the
    /// main actor: these builders are `nonisolated` by necessity. `--selftest-tool-awareness`
    /// checks the two agree.
    static let identityFileName = "agent-identity.json"
    static let defaultAssistantName = "Next"

    /// `agent-identity.json`'s display name, read directly rather than through the
    /// main-actor store. Falls back to the store's own default.
    static func assistantName() -> String {
        let url = AppIdentity.applicationSupportDirectory
            .appendingPathComponent(identityFileName)
        let modified = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        lock.lock()
        if let identity, identity.modified == modified {
            defer { lock.unlock() }
            return identity.name
        }
        lock.unlock()
        var name = defaultAssistantName
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let saved = object["displayName"] as? String {
            let trimmed = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { name = String(trimmed.prefix(40)) }
        }
        lock.lock()
        identity = Cached(name: name, modified: modified)
        lock.unlock()
        return name
    }

    /// The account holder, as macOS has it. `ActionItemReminders.localUserNames` already
    /// treats this as the user's identity for meeting owners; the Agent now says it out loud.
    static func userFullName() -> String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        // A short-name-only account ("sergekadjo") is not a name a person would be called.
        guard full.contains(" ") || full.rangeOfCharacter(from: .uppercaseLetters) != nil else {
            return ""
        }
        return String(full.prefix(60))
    }
}

/// The two facts the main actor owns, published where the prompt builders can read them.
///
/// Same shape and the same reason as `MemorySnapshotCache`: a lock rather than an actor,
/// because the readers are `nonisolated` prompt builders that cannot await.
final class AgentGroundingCache: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        var folders: [String] = []
        var indexedItems: Int = 0
        /// The live planner roster. Defaults to the allow-list minus the namespaces whose
        /// switch is off, so a prompt assembled before anything published still says only
        /// what the planner would in fact be given.
        var toolIDs: Set<String> = AgentGroundingCache.defaultToolIDs()
    }

    static let shared = AgentGroundingCache()

    private let lock = NSLock()
    private var value = Snapshot()

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func publish(folders: [String], indexedItems: Int, toolIDs: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        value = Snapshot(folders: folders, indexedItems: indexedItems, toolIDs: toolIDs)
    }

    func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        value = Snapshot()
    }

    /// What the planner would be allowed to call, judged from the switches alone.
    static func defaultToolIDs() -> Set<String> {
        var ids = RealtimeToolSelection.allowedIDs
        if !MemorySnapshotCache.defaultsEnabled { ids.subtract(MemoryToolCatalogue.ids) }
        if !ScheduleSettingsSnapshot.defaultsEnabled { ids.subtract(ScheduleToolCatalogue.ids) }
        return ids
    }
}
