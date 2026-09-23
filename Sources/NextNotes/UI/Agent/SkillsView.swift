import AppKit
import SwiftUI

/// Agent ▸ Skills — "things your assistant knows how to do".
///
/// The whole point of this pane is that nothing technical appears on it. There is no repo, no
/// package, no command, no version and no path: a skill is a thing the assistant knows, it
/// either came with another app on this Mac or the user added it, and a switch turns it off.
/// The words "install", "registry", "GitHub", "YAML" and "frontmatter" are all deliberately
/// absent — "Add", "on your Mac", "the project it came from" say the same thing to someone
/// who has never opened a terminal.
///
/// The list below the search field is the whole library: filter it, group it, sort it, switch
/// several at once, and remove the ones Next Notes itself added. What it will not do is offer
/// a delete it cannot honour — a skill in another assistant's folder says so on its card and
/// the button is simply absent.
struct SkillsView: View {
    init() {}

    @State private var library = SkillLibrary.shared
    @State private var model = SkillsSearchModel()
    @State private var query = ""
    @State private var filter = SkillFilter()
    @State private var selection: Set<String> = []
    @State private var isSelecting = false
    @State private var pendingRemoval: [Skill] = []
    @State private var pendingSkipped = 0
    @State private var showsRemovalConfirmation = false
    @State private var expanded: Set<String> = []
    @State private var message: String?
    @State private var messageIsProblem = true
    @State private var undo: SkillsUndo?

    var body: some View {
        AgentPaneScroll {
            header
            finder
            filterBar
            librarySection
            if let undo { undoBar(undo) }
            if let message { note(message, warning: messageIsProblem) }
        }
        .task {
            if library.lastScan == nil { await library.rescan() }
        }
        .confirmationDialog(
            removalTitle,
            isPresented: $showsRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { performRemoval(pendingRemoval) }
            Button("Cancel", role: .cancel) {
                pendingRemoval = []
                pendingSkipped = 0
            }
        } message: {
            Text(removalMessage)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            AgentPaneHeader(title: "Skills", subtitle: countLine) {
                HStack(spacing: DS.Space.s) {
                    if library.isScanning {
                        ProgressView().controlSize(.small)
                    }
                    Button("Look again") { Task { await library.rescan() } }
                        .buttonStyle(.borderless)
                        .font(DS.Font.caption)
                        .disabled(library.isScanning)
                    Toggle("Use skills", isOn: Binding(
                        get: { library.isEnabled },
                        set: { library.isEnabled = $0 }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Use skills")
                }
            }
            Text("Things your assistant knows how to do. It reads one only when it needs it.")
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: DS.Size.agentProseMaxWidth, alignment: .leading)
        }
    }

    /// The live counts sentence in the header. While the scan is in flight it says so
    /// rather than showing a number from before it started.
    private var countLine: String {
        library.isScanning ? "Looking…" : SkillsCopy.countLine(library.counts)
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
                GlassGroup(spacing: DS.Space.card) {
                    AgentCardGrid(minimum: DS.Size.skillCardMin) {
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

    // MARK: - Everything on your Mac

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Everything on your Mac").font(DS.Font.sectionLabel)
                Spacer()
                if !library.skills.isEmpty {
                    Button(isSelecting ? "Done" : "Select") { toggleSelecting() }
                        .buttonStyle(.borderless)
                        .font(DS.Font.caption)
                }
            }
            if isSelecting || !selection.isEmpty { selectionBar }
            if library.skills.isEmpty {
                if library.isScanning {
                    HStack(spacing: DS.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Looking…").font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                    }
                } else {
                    note("No skills found on this Mac yet. Search above to add one, and anything "
                         + "your other assistants already have will show up here.", warning: false)
                }
            } else if visibleSkills.isEmpty {
                note(filter.emptyReason, warning: false)
            } else {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        if let title = group.title { groupHeading(title, group: group) }
                        GlassGroup(spacing: DS.Space.card) {
                            AgentCardGrid(minimum: DS.Size.skillCardMin) {
                                ForEach(group.skills) { skill in card(skill) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var visibleSkills: [Skill] {
        let matched = filter.apply(
            to: library.skills,
            isOn: { library.isOn($0) },
            origin: { library.origin(of: $0) })
        return SkillOrganizer.sorted(matched, by: library.sort, installedAt: { library.installedAt(of: $0) })
    }

    private var groups: [SkillGroup] {
        SkillOrganizer.groups(visibleSkills, by: library.grouping, origin: { library.origin(of: $0) })
    }

    private func groupHeading(_ title: String, group: SkillGroup) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(title).font(DS.Font.sectionLabel)
                Text("\(group.skills.count)")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textTertiary)
            }
            if let subtitle = group.subtitle {
                Text(subtitle)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        // A wrapping row, not an `HStack`: six controls do not fit across a 560pt pane, and a
        // squeezed menu draws as an unreadable ellipsis.
        FlowLayout(spacing: DS.Space.s) {
            TextField("Narrow this list", text: $filter.text)
                .textFieldStyle(.roundedBorder)
                .frame(width: DS.Size.settingsFieldWidth)
            statePicker
            sourceMenu
            originMenu
            groupingPicker
            sortPicker
        }
    }

    /// All / On / Off. The filter type carries a set because more than one answer may be
    /// wanted later; the control offers the three states that make sense today.
    private var statePicker: some View {
        Picker("Switch", selection: Binding(
            get: { filter.states.count == 1 ? filter.states.first : nil },
            set: { value in filter.states = value.map { Set([$0]) } ?? [] }
        )) {
            Text("All").tag(nil as SkillStateFilter?)
            ForEach(SkillStateFilter.allCases) { state in
                Text(state.displayName).tag(state as SkillStateFilter?)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Switch position")
    }

    /// The apps are whatever the library actually found, in `allCases` order — a hard-coded
    /// list would drift the moment a root is added or removed.
    private var sourceMenu: some View {
        Menu {
            ForEach(SkillFilter.availableSources(in: library.skills), id: \.self) { source in
                Toggle(source.badge, isOn: Binding(
                    get: { filter.sources.contains(source) },
                    set: { on in
                        if on { filter.sources.insert(source) } else { filter.sources.remove(source) }
                    }))
            }
            if !filter.sources.isEmpty {
                Divider()
                Button("Any app") { filter.sources = [] }
            }
        } label: {
            Text(sourceMenuLabel)
        }
        .fixedSize()
    }

    private var sourceMenuLabel: String {
        switch filter.sources.count {
        case 0: "From: any app"
        case 1: "From: " + (filter.sources.first?.badge ?? "")
        default: "From: \(filter.sources.count) apps"
        }
    }

    private var originMenu: some View {
        Menu {
            ForEach(SkillFilter.availableOrigins(in: library.skills, origin: { library.origin(of: $0) })) { origin in
                Toggle(origin.badge, isOn: Binding(
                    get: { filter.origins.contains(origin) },
                    set: { on in
                        if on { filter.origins.insert(origin) } else { filter.origins.remove(origin) }
                    }))
            }
            if !filter.origins.isEmpty {
                Divider()
                Button("Any origin") { filter.origins = [] }
            }
        } label: {
            Text(originMenuLabel)
        }
        .fixedSize()
    }

    private var originMenuLabel: String {
        switch filter.origins.count {
        case 0: "Came from: anywhere"
        case 1: "Came from: " + (filter.origins.first?.badge ?? "")
        default: "Came from: \(filter.origins.count) kinds"
        }
    }

    private var groupingPicker: some View {
        Picker("Group", selection: Binding(
            get: { library.grouping },
            set: { library.grouping = $0 }
        )) {
            ForEach(SkillGrouping.allCases) { grouping in
                Text("Group: " + grouping.displayName).tag(grouping)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Group skills")
    }

    private var sortPicker: some View {
        Picker("Sort", selection: Binding(
            get: { library.sort },
            set: { library.sort = $0 }
        )) {
            ForEach(SkillSort.allCases) { sort in
                Text("Sort: " + sort.displayName).tag(sort)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Sort skills")
    }

    // MARK: - Selection

    private var selectedSkills: [Skill] {
        library.skills.filter { selection.contains($0.id) }
    }

    private var removableSelection: [Skill] {
        selectedSkills.filter { library.origin(of: $0).isRemovable }
    }

    private var allVisibleSelected: Bool {
        !visibleSkills.isEmpty && visibleSkills.allSatisfy { selection.contains($0.id) }
    }

    private var selectionBar: some View {
        HStack(spacing: DS.Space.s) {
            Text("\(selection.count) selected")
                .font(DS.Font.callout)
            Spacer(minLength: DS.Space.s)
            Button(allVisibleSelected ? "None" : "Select all") {
                if allVisibleSelected {
                    selection.subtract(visibleSkills.map(\.id))
                } else {
                    selection.formUnion(visibleSkills.map(\.id))
                }
            }
            .buttonStyle(.borderless)
            .font(DS.Font.caption)
            .disabled(visibleSkills.isEmpty)
            Button("Turn on \(selection.count)") {
                switchOn(selectedSkills, true)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selection.isEmpty)
            Button("Turn off \(selection.count)") {
                switchOn(selectedSkills, false)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selection.isEmpty)
            Button("Remove \(removableSelection.count)…") {
                askRemoval(selectedSkills)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(removableSelection.isEmpty)
        }
        .padding(DS.Space.cardTight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.card)
    }

    private func toggleSelecting() {
        if isSelecting {
            isSelecting = false
            selection = []
        } else {
            isSelecting = true
        }
    }

    private func toggleSelection(_ skill: Skill) {
        if selection.contains(skill.id) {
            selection.remove(skill.id)
        } else {
            selection.insert(skill.id)
            isSelecting = true
        }
    }

    private func switchOn(_ skills: [Skill], _ on: Bool) {
        guard !skills.isEmpty else { return }
        library.setOn(skills, on)
        messageIsProblem = false
        message = "\(SkillsCopy.counted(skills.count)) switched \(on ? "on" : "off")."
    }

    // MARK: - One card

    private func card(_ skill: Skill) -> some View {
        let origin = library.origin(of: skill)
        let selected = selection.contains(skill.id)
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                if isSelecting || selected {
                    selectButton(skill, selected: selected)
                }
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
            if !origin.isRemovable {
                Text(origin.readOnlyExplanation)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textTertiary)
            }
            Spacer(minLength: 0)
            HStack(spacing: DS.Space.m) {
                Button(expanded.contains(skill.id) ? "Hide what it says" : "See what it says") {
                    if expanded.contains(skill.id) { expanded.remove(skill.id) } else { expanded.insert(skill.id) }
                }
                .buttonStyle(.borderless)
                .font(DS.Font.caption)
                if origin.isRemovable {
                    Button("Update") { update(skill) }
                        .buttonStyle(.borderless)
                        .font(DS.Font.caption)
                        .disabled(model.adding.contains(skill.name))
                    Button("Remove") { askRemoval([skill]) }
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
        .contentShape(Rectangle())
        // ⌘-click selects anywhere on the card; a plain click selects only while the toolbar
        // is up, so ordinary browsing is not turned into accidental selection. One gesture
        // rather than an onTapGesture plus a modified one: two would both fire on ⌘-click
        // and cancel each other out.
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) || isSelecting {
                toggleSelection(skill)
            }
        }
    }

    private func selectButton(_ skill: Skill, selected: Bool) -> some View {
        Button {
            toggleSelection(skill)
        } label: {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? DS.Color.accent : DS.Color.textTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selected
            ? "Deselect \(SkillsCopy.title(skill.name))"
            : "Select \(SkillsCopy.title(skill.name))")
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

    // MARK: - Removal

    private var removalTitle: String {
        guard let first = pendingRemoval.first else { return "Remove these skills?" }
        return pendingRemoval.count == 1
            ? "Remove “\(SkillsCopy.title(first.name))”?"
            : "Remove \(pendingRemoval.count) skills?"
    }

    private var removalMessage: String {
        guard !pendingRemoval.isEmpty else { return "" }
        let named = pendingRemoval.prefix(6).map { "“\(SkillsCopy.title($0.name))”" }
        var text = "Removes " + named.joined(separator: ", ")
        if pendingRemoval.count > named.count {
            text += " and \(pendingRemoval.count - named.count) more"
        }
        text += ". This can't be undone."
        if pendingSkipped > 0 {
            text += " \(SkillsCopy.counted(pendingSkipped)) you picked "
                + (pendingSkipped == 1 ? "was" : "were")
                + " not added by Next Notes, so "
                + (pendingSkipped == 1 ? "it stays" : "they stay") + " where "
                + (pendingSkipped == 1 ? "it is" : "they are") + "."
        }
        return text
    }

    /// Opens the confirmation for anything removable among `skills`. The shared ones are
    /// counted so the dialog can say they are staying, rather than silently dropping them.
    private func askRemoval(_ skills: [Skill]) {
        let removable = skills.filter { library.origin(of: $0).isRemovable }
        guard !removable.isEmpty else { return }
        pendingRemoval = removable
        pendingSkipped = skills.count - removable.count
        showsRemovalConfirmation = true
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

    /// One path for one skill and for twenty: the dialog has already named what goes.
    private func performRemoval(_ skills: [Skill]) {
        let removing = skills
        pendingRemoval = []
        pendingSkipped = 0
        guard !removing.isEmpty else { return }
        message = nil
        messageIsProblem = true
        // Read the provenance before the lock entry is deleted — afterwards there is nothing
        // left to rebuild an Undo from.
        let singleSource = removing.count == 1 ? model.origin(of: removing[0], library: library) : nil
        Task {
            let problem = await model.remove(names: removing.map(\.name), library: library)
            selection.subtract(removing.map(\.id))
            if let problem {
                message = problem
            } else {
                messageIsProblem = false
                message = "Removed \(SkillsCopy.counted(removing.count)) from your Mac."
                if let skill = removing.first, let singleSource {
                    undo = SkillsUndo(
                        message: "Removed “\(SkillsCopy.title(skill.name))”.",
                        action: .add(singleSource))
                }
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

    static func counted(_ count: Int) -> String {
        "\(count) skill\(count == 1 ? "" : "s")"
    }

    /// The live counts line. Every number the pane claims is in here, so the header cannot
    /// say "177 found" while the grid shows something else.
    static func countLine(_ counts: SkillCounts) -> String {
        guard counts.total > 0 else { return "Nothing found on this Mac yet." }
        var line = "\(counts.total) skill\(counts.total == 1 ? "" : "s") found — "
            + "\(counts.on) on, \(counts.off) switched off"
        var parts: [String] = []
        if counts.installed > 0 { parts.append("\(counts.installed) installed by Next Notes") }
        if counts.inOurFolder > 0 { parts.append("\(counts.inOurFolder) in your skills folder") }
        if counts.shared > 0 { parts.append("\(counts.shared) shared") }
        if !parts.isEmpty { line += " · " + parts.joined(separator: ", ") }
        return line
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
        await remove(names: [skill.name], library: library)
    }

    /// Removes several in one lock write. Returns a sentence only when something went wrong;
    /// anything that was not installed by Next Notes is skipped inside the client.
    func remove(names: [String], library: SkillLibrary) async -> String? {
        do {
            let outcome = try SkillRegistryClient(directory: library.installDirectory).remove(names: names)
            await library.refreshInstalled()
            guard outcome.failures.isEmpty else {
                return outcome.failures
                    .sorted { $0.key < $1.key }
                    .map { "“\(SkillsCopy.title($0.key))”: \($0.value)" }
                    .joined(separator: " ")
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
