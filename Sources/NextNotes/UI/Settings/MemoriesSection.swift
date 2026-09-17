import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Agent → Memories, on the same pattern as *Remembered permissions*.
///
/// Memories save without a prompt (decision 1), so this list is where the user sees and
/// undoes every one: source, date and session, edit in place, Forget, *Forget everything*,
/// a *New* badge on what the background review added since the list was last closed (the
/// Agent tab marks them seen when it closes: a lazy Form row can disappear on scroll), budget
/// meters, and a Markdown export. Activity items are derived and rebuild themselves, so they
/// sit collapsed underneath.
struct MemoriesSection: View {
    @State private var settings = Settings.shared
    @State private var memory = NextMemory.shared
    @State private var editingID: UUID?
    @State private var draft = ""
    @State private var newText = ""
    @State private var newKind: MemoryEntry.Kind = .profile
    @State private var error: String?
    @State private var confirmingForgetAll = false
    @State private var showActivity = false

    var body: some View {
        Section {
            Toggle("Remember what I tell the Agent", isOn: $settings.agentMemoryEnabled)

            Picker("Review conversations with", selection: $settings.agentMemoryReviewModel) {
                ForEach(MemoryReviewModelChoice.allCases) { choice in
                    Text(choice.displayName).tag(choice.rawValue)
                }
            }
            .disabled(!settings.agentMemoryEnabled)
            SettingsNote(text: (MemoryReviewModelChoice(rawValue: settings.agentMemoryReviewModel) ?? .auto).summary
                         + " It never runs while a meeting or dictation is recording.")

            Stepper("New conversation after \(settings.agentSessionIdleMinutes) minutes of silence",
                    value: $settings.agentSessionIdleMinutes, in: 5...240, step: 5)

            HStack(spacing: DS.Space.m) {
                ForEach(MemoryEntry.Kind.allCases, id: \.self) { kind in
                    meter(kind)
                }
            }

            ForEach(MemoryEntry.Kind.allCases, id: \.self) { kind in
                let rows = memory.entries(of: kind)
                Text(kind.displayName)
                    .font(DS.Font.headline)
                if rows.isEmpty {
                    Text("None yet")
                        .foregroundStyle(DS.Color.textSecondary)
                }
                ForEach(rows) { entry in
                    row(entry)
                }
            }

            HStack(spacing: DS.Space.s) {
                Picker("", selection: $newKind) {
                    ForEach(MemoryEntry.Kind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .fixedSize()
                TextField("Add a fact, e.g. “The user prefers short answers.”", text: $newText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let error {
                Text(error)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
            }

            HStack {
                Button("Export as Markdown…", action: export)
                Spacer()
                Button("Forget everything", role: .destructive) { confirmingForgetAll = true }
                    .disabled(memory.entries.isEmpty && memory.items.isEmpty)
                    .confirmationDialog("Forget every memory, its history and the activity index?",
                                        isPresented: $confirmingForgetAll) {
                        Button("Forget everything", role: .destructive) {
                            perform { try memory.forgetEverything() }
                        }
                    }
            }

            DisclosureGroup("Names and labels from activity (\(memory.items.count))", isExpanded: $showActivity) {
                if memory.items.isEmpty {
                    Text("None yet")
                        .foregroundStyle(DS.Color.textSecondary)
                } else {
                    ForEach(memory.items.sorted(by: { $0.updatedAt > $1.updatedAt })) { item in
                        LabeledContent(item.value) {
                            Text(item.kind.rawValue)
                                .foregroundStyle(DS.Color.textSecondary)
                        }
                    }
                }
            }
        } header: {
            Text("Memories")
        } footer: {
            SettingsNote(text: "The Agent saves facts you tell it about yourself and says out loud "
                         + "what it saved. When a conversation ends it reviews what you said and may "
                         + "add a few more, marked New. It never saves anything from email, web pages, files or "
                         + "other tool results, and a memory never grants permission. Changes reach "
                         + "the Agent at its next conversation; Forget takes effect immediately. When "
                         + "OpenRouter is the Agent model, memories are sent with each request. "
                         + "Coding agents never receive them.")
        }
    }

    private func meter(_ kind: MemoryEntry.Kind) -> some View {
        let used = memory.used(kind)
        return VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text("\(kind.displayName) \(used.formatted()) / \(kind.budget.formatted())")
                .font(DS.Font.caption)
                .foregroundStyle(used >= kind.budget * 9 / 10 ? DS.Color.warning : DS.Color.textSecondary)
            ProgressView(value: Double(min(used, kind.budget)), total: Double(kind.budget))
        }
    }

    @ViewBuilder
    private func row(_ entry: MemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if editingID == entry.id {
                TextField("Memory", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save(entry) }
                HStack {
                    Button("Save") { save(entry) }
                    Button("Cancel") { editingID = nil }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text(entry.text)
                        .textSelection(.enabled)
                    if memory.isNew(entry) {
                        Text("New")
                            .font(DS.Font.caption)
                            .padding(.horizontal, DS.Space.xs)
                            .background(DS.Color.accent.opacity(0.2), in: Capsule())
                    }
                    Spacer()
                    Button("Edit") {
                        draft = entry.text
                        editingID = entry.id
                    }
                    if entry.supersedes != nil {
                        Button("Undo change") { perform { try memory.undoSupersede(id: entry.id) } }
                    }
                    Button("Forget") { perform { try memory.forget(id: entry.id) } }
                }
                Text(detail(entry))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                if let reason = memory.flagged[entry.id] {
                    Text("Not used by the Agent: \(reason)")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.warning)
                }
            }
        }
    }

    private func detail(_ entry: MemoryEntry) -> String {
        var parts = [entry.source.displayName, entry.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if entry.updatedAt > entry.createdAt { parts.append("edited") }
        if let session = entry.sessionID {
            parts.append("conversation \(session.uuidString.prefix(8).lowercased())")
        }
        return parts.joined(separator: " · ")
    }

    private func add() {
        let text = newText
        perform {
            try memory.remember(kind: newKind, text: text, source: .manual)
            newText = ""
        }
    }

    private func save(_ entry: MemoryEntry) {
        let text = draft
        perform {
            try memory.edit(id: entry.id, text: text)
            editingID = nil
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Next Notes memories.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try Data(memory.markdownExport().utf8).write(to: url, options: .atomic) }
    }
}
