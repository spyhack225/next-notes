import SwiftUI

/// Agent ▸ Skills — "things your assistant knows how to do".
///
/// The whole point of this pane is that nothing technical appears on it. There is no repo, no
/// package, no command, no version and no path: a skill is a thing the assistant knows, it
/// either came with another app on this Mac or the user added it, and a switch turns it off.
/// The words "install", "registry", "GitHub", "YAML" and "frontmatter" are all deliberately
/// absent — "Add", "on your Mac", "the project it came from" say the same thing to someone
/// who has never opened a terminal.
struct SkillsView: View {
    init() {}

    @State private var library = SkillLibrary.shared
    @State private var model = SkillsSearchModel()
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var message: String?
    @State private var messageIsProblem = true
    @State private var undo: SkillsUndo?
    /// Appears once the list is long enough that scrolling it is worse than typing.
    @State private var filter = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.xl) {
                header
                finder
                if let undo { undoBar(undo) }
                if let message { note(message, warning: messageIsProblem) }
                addedByYou
                alreadyHere
            }
            .padding(DS.Space.page)
            .frame(maxWidth: DS.Size.agentSkillsMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .task {
            if library.lastScan == nil { await library.rescan() }
        }
    }

    /// The adaptive grid every card section lays out into: 2–3 columns on a wide window,
    /// one on a narrow one, rather than a single 560pt column with the rest of the pane
    /// sitting empty.
    private var cardColumns: [GridItem] {
        [GridItem(.adaptive(minimum: DS.Size.skillCardMin), spacing: DS.Space.m)]
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("Skills")
                    .font(DS.Font.title2.weight(.semibold))
                    .tracking(DS.Font.wordTracking)
                Spacer()
                Toggle("Use skills", isOn: Binding(
                    get: { library.isEnabled },
                    set: { library.isEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Use skills")
            }
            Text("Things your assistant knows how to do. It reads one only when it needs it.")
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
            HStack(spacing: DS.Space.s) {
                if library.isScanning {
                    ProgressView().controlSize(.small)
                    Text("Looking…").font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                } else {
                    Text(countLine)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
                Button("Look again") { Task { await library.rescan() } }
                    .buttonStyle(.borderless)
                    .font(DS.Font.caption)
                    .disabled(library.isScanning)
            }
        }
    }

    private var countLine: String {
        let total = library.skills.count
        guard total > 0 else { return "Nothing found on this Mac yet." }
        let off = library.skills.filter { !library.isOn($0) }.count
        let on = "\(total) skill\(total == 1 ? "" : "s") found"
        return off == 0 ? on : "\(on), \(off) switched off"
    }

    // MARK: - Find a new skill

    private var finder: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Find a new skill").font(DS.Font.sectionLabel)
            HStack(spacing: DS.Space.s) {
                TextField("What would you like it to be able to do?", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                Button("Search", action: search)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || model.isSearching)
            }
            if model.isSearching {
                HStack(spacing: DS.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Searching…").font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                }
            }
            if let problem = model.problem { note(problem, warning: true) }
            if !model.results.isEmpty {
                GlassGroup(spacing: DS.Space.m) {
                    LazyVGrid(columns: cardColumns, spacing: DS.Space.m) {
                        ForEach(model.results) { result in
                            foundRow(result)
                        }
                    }
                }
            }
            if model.hasSearched, model.results.isEmpty, model.problem == nil {
                note("Nothing matched. Try different words — “write meeting notes”, “read a PDF”.",
                     warning: false)
            }
        }
    }

    private func foundRow(_ result: RegistrySkill) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(SkillsCopy.title(result.name))
                    .font(DS.Font.headline)
                    .lineLimit(1)
                Spacer()
                addButton(result)
            }
            Text(model.description(for: result) ?? "Checking what this one does…")
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .lineLimit(3)
            Spacer(minLength: 0)
            Text(SkillsCopy.popularity(result.installs))
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textTertiary)
        }
        .padding(DS.Space.cardTight)
        .frame(maxWidth: .infinity, minHeight: DS.Size.skillCardMinHeight, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.card)
    }

    @ViewBuilder
    private func addButton(_ result: RegistrySkill) -> some View {
        if library.skill(named: result.installName) != nil {
            Label("On your Mac", systemImage: "checkmark")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.success)
        } else if model.adding.contains(result.id) {
            ProgressView().controlSize(.small)
        } else {
            Button("Add") { add(result) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    // MARK: - Added by you

    @ViewBuilder
    private var addedByYou: some View {
        let mine = library.installed
        if !mine.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("Added by you").font(DS.Font.sectionLabel)
                GlassGroup(spacing: DS.Space.m) {
                    LazyVGrid(columns: cardColumns, spacing: DS.Space.m) {
                        ForEach(mine) { skill in row(skill, removable: true) }
                    }
                }
            }
        }
    }

    // MARK: - Already on your Mac

    @ViewBuilder
    private var alreadyHere: some View {
        let others = library.fromOtherApps
        let shown = matching(others)
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Already on your Mac").font(DS.Font.sectionLabel)
                Spacer()
                if others.count > 12 {
                    TextField("Narrow this list", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: DS.Size.settingsFieldWidth)
                }
            }
            if others.isEmpty {
                note("Your other assistants have not left any skills here. Anything you add above "
                     + "shows up under “Added by you”.", warning: false)
            } else {
                Text("These came with other assistants you already use. Next Notes reads them where "
                     + "they are and never changes them.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                if shown.isEmpty {
                    note("Nothing here matches what you typed.", warning: false)
                }
                GlassGroup(spacing: DS.Space.m) {
                    LazyVGrid(columns: cardColumns, spacing: DS.Space.m) {
                        ForEach(shown) { skill in row(skill, removable: false) }
                    }
                }
            }
        }
    }

    /// Name or description contains what was typed. A plain substring: the user is scanning a
    /// list they can see, not running a query.
    private func matching(_ skills: [Skill]) -> [Skill] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return skills }
        return skills.filter {
            $0.name.lowercased().contains(needle) || $0.description.lowercased().contains(needle)
        }
    }

    // MARK: - One row

    private func row(_ skill: Skill, removable: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(SkillsCopy.title(skill.name))
                    .font(DS.Font.headline)
                    .foregroundStyle(library.isOn(skill) ? DS.Color.text : DS.Color.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: DS.Space.s)
                Toggle("", isOn: Binding(
                    get: { library.isOn(skill) },
                    set: { library.setOn(skill, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel("Use \(SkillsCopy.title(skill.name))")
            }
            HStack(spacing: DS.Space.xs) {
                badge(skill.source.badge)
                ForEach(skill.alsoIn, id: \.self) { badge($0.badge) }
            }
            Text(skill.summary(limit: 200))
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .lineLimit(3)
            if skill.isShadowed {
                Text("Another skill has the same name, so your assistant uses that one.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
            }
            Spacer(minLength: 0)
            HStack(spacing: DS.Space.m) {
                Button(expanded.contains(skill.id) ? "Hide what it says" : "See what it says") {
                    if expanded.contains(skill.id) { expanded.remove(skill.id) } else { expanded.insert(skill.id) }
                }
                .buttonStyle(.borderless)
                .font(DS.Font.caption)
                if removable {
                    Button("Update") { update(skill) }
                        .buttonStyle(.borderless)
                        .font(DS.Font.caption)
                        .disabled(model.adding.contains(skill.name))
                    Button("Remove") { remove(skill) }
                        .buttonStyle(.borderless)
                        .font(DS.Font.caption)
                }
                Spacer()
                Text(SkillsCopy.fileCount(skill.files.count))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textTertiary)
            }
            if expanded.contains(skill.id) {
                ScrollView {
                    Text(SkillsCopy.preview(of: skill))
                        .font(DS.Font.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: DS.Size.messagePreviewHeight)
                .padding(DS.Space.s)
                .background(DS.Color.groupedFill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            }
        }
        .padding(DS.Space.cardTight)
        .frame(maxWidth: .infinity, minHeight: DS.Size.skillCardMinHeight, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.card)
        .opacity(library.isOn(skill) ? 1 : 0.6)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.chip)
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, DS.Space.xxs)
            .background(DS.Color.groupedFill, in: Capsule())
            .foregroundStyle(DS.Color.textSecondary)
    }

    private func note(_ text: String, warning: Bool) -> some View {
        Text(text)
            .font(DS.Font.caption)
            .foregroundStyle(warning ? DS.Color.warning : DS.Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func undoBar(_ undo: SkillsUndo) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(undo.message).font(DS.Font.callout)
            Spacer()
            Button("Undo") {
                self.undo = nil
                Task { await perform(undo.action) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button {
                self.undo = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(DS.Space.cardTight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.card)
    }

    // MARK: - Actions

    private func search() {
        message = nil
        messageIsProblem = true
        Task { await model.search(query, library: library) }
    }

    private func add(_ result: RegistrySkill) {
        message = nil
        messageIsProblem = true
        Task {
            if let problem = await model.add(result, library: library) {
                message = problem
            } else {
                undo = SkillsUndo(
                    message: "Added “\(SkillsCopy.title(result.name))”.",
                    action: .remove(name: result.installName))
            }
        }
    }

    private func update(_ skill: Skill) {
        message = nil
        Task {
            // "Already the newest" is news, not a problem, and must not be shown in orange.
            let outcome = await model.update(skill, library: library)
            messageIsProblem = outcome != nil && !(outcome?.contains("already the newest") ?? false)
            message = outcome
            undo = nil
        }
    }

    private func remove(_ skill: Skill) {
        message = nil
        messageIsProblem = true
        let source = model.origin(of: skill, library: library)
        Task {
            if let problem = await model.remove(skill, library: library) {
                message = problem
            } else if let source {
                undo = SkillsUndo(
                    message: "Removed “\(SkillsCopy.title(skill.name))”.",
                    action: .add(source))
            }
        }
    }

    private func perform(_ action: SkillsUndo.Action) async {
        switch action {
        case .remove(let name):
            if let skill = library.skill(named: name) {
                message = await model.remove(skill, library: library)
            }
        case .add(let result):
            message = await model.add(result, library: library)
        }
    }
}

/// One step the user can take back. Adding and removing are each other's opposite, which is
/// the only reason an undo is honest here.
struct SkillsUndo: Equatable {
    enum Action: Equatable {
        case remove(name: String)
        case add(RegistrySkill)
    }

    let message: String
    let action: Action
}

/// Plain-language strings, in one place so the pane and any future card agree.
enum SkillsCopy {
    /// `pdf-forms` reads as "Pdf forms" to someone who has never seen a folder name.
    static func title(_ name: String) -> String {
        let words = name.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func popularity(_ installs: Int) -> String {
        installs <= 0 ? "New" : "\(installs.formatted()) people use this"
    }

    static func fileCount(_ count: Int) -> String {
        count <= 1 ? "1 page" : "\(count) pages"
    }

    /// The first part of what a skill actually says, so the user can judge it before
    /// switching it on. Text only — nothing here runs.
    static func preview(of skill: Skill, limit: Int = 1_500) -> String {
        guard let data = FileManager.default.contents(atPath: skill.skillFile.path),
              let text = String(data: data, encoding: .utf8) else {
            return "This skill's text could not be read."
        }
        let body = SkillFrontmatter.parse(text)?.body ?? text
        return body.count > limit ? String(body.prefix(limit)) + "…" : body
    }
}

/// The searching and adding half of the pane, kept out of the view so the view stays layout.
@MainActor
@Observable
final class SkillsSearchModel {
    private(set) var results: [RegistrySkill] = []
    private(set) var isSearching = false
    private(set) var hasSearched = false
    private(set) var problem: String?
    private(set) var adding: Set<String> = []
    /// Descriptions arrive one request later than the names — the directory does not carry
    /// them — so they fill in under the rows the user is already looking at.
    private var descriptions: [String: String] = [:]

    func description(for result: RegistrySkill) -> String? {
        result.description ?? descriptions[result.id]
    }

    func origin(of skill: Skill, library: SkillLibrary) -> RegistrySkill? {
        let store = SkillLockStore(directory: library.installDirectory)
        guard let entry = store.entry(named: skill.name) else { return nil }
        return RegistrySkill(id: entry.id, skillId: entry.skillId, name: entry.name,
                             source: entry.source, installs: 0)
    }

    func search(_ query: String, library: SkillLibrary) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        problem = nil
        defer { isSearching = false; hasSearched = true }
        let client = SkillRegistryClient(directory: library.installDirectory)
        do {
            let hits = try await client.search(trimmed, limit: 12)
            results = hits
            await fillDescriptions(for: Array(hits.prefix(6)), client: client)
        } catch {
            results = []
            problem = error.localizedDescription
        }
    }

    /// Reads the first line of each result's own text. Sequential on purpose: six polite
    /// requests beat six simultaneous ones against an unauthenticated rate limit, and the
    /// rows fill in as they arrive.
    private func fillDescriptions(for hits: [RegistrySkill], client: SkillRegistryClient) async {
        for hit in hits where descriptions[hit.id] == nil {
            guard let described = try? await client.describe(hit),
                  let text = described.description, !text.isEmpty else {
                descriptions[hit.id] = "No description — open it to see what it says."
                continue
            }
            descriptions[hit.id] = text
        }
    }

    /// Adds a skill. Returns a sentence to show when it did not work, nil when it did.
    func add(_ result: RegistrySkill, library: SkillLibrary) async -> String? {
        guard !adding.contains(result.id) else { return nil }
        adding.insert(result.id)
        defer { adding.remove(result.id) }
        do {
            _ = try await SkillRegistryClient(directory: library.installDirectory).install(result)
            await library.refreshInstalled()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Returns a sentence either way: "already the newest" is news too.
    func update(_ skill: Skill, library: SkillLibrary) async -> String? {
        adding.insert(skill.name)
        defer { adding.remove(skill.name) }
        do {
            let updated = try await SkillRegistryClient(directory: library.installDirectory)
                .update(name: skill.name)
            await library.refreshInstalled()
            return updated == nil
                ? "“\(SkillsCopy.title(skill.name))” is already the newest version."
                : nil
        } catch {
            return error.localizedDescription
        }
    }

    func remove(_ skill: Skill, library: SkillLibrary) async -> String? {
        do {
            try SkillRegistryClient(directory: library.installDirectory).remove(name: skill.name)
            await library.refreshInstalled()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
