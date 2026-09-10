import NextNotesDictionary
import AppKit
import SwiftUI

/// The dictionary: add, edit, delete, search.
///
/// Both entry kinds live in one list rather than separate tabs — they're two shapes of the
/// same idea and you want to see everything you've taught it at once. The kind is carried
/// by a chip on each row.
struct DictionaryPanel: View {
    @State private var store = DictionaryStore.shared
    @State private var query = ""
    @State private var editing: DictionaryEntry?
    @State private var isAdding = false

    private var entries: [DictionaryEntry] { store.filtered(by: query) }

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(entries) { entry in
                        DictionaryRow(entry: entry) {
                            var updated = entry
                            updated.isEnabled.toggle()
                            store.update(updated)
                        }
                        .contentShape(.rect)
                        .onTapGesture(count: 2) { editing = entry }
                        .contextMenu {
                            Button("Edit…") { editing = entry }
                            Button(entry.isEnabled ? "Disable" : "Enable") {
                                var updated = entry
                                updated.isEnabled.toggle()
                                store.update(updated)
                            }
                            Button("Delete", role: .destructive) { store.delete(entry) }
                        }
                    }
                }
                .listStyle(.inset)
                // No alternating backgrounds here, unlike the Dictation list. AppKit paints
                // those bands over the whole view, not just the rows that exist, so a
                // dictionary holding five entries in a tall window shows five entries and
                // twenty empty stripes that read as broken placeholder rows. Dictation earns
                // them because its rows are multi-line paragraphs that need separating and
                // its list is usually long; a one-line term with a checkbox and a chip does
                // not need help being told apart from its neighbour.
            }

            Divider()
            footer
        }
        .navigationTitle(SidebarSection.dictionary.title)
        .searchable(text: $query, prompt: Text("Search dictionary"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { isAdding = true } label: {
                    Label("Add Entry", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("Add a word or a correction")
            }
        }
        .sheet(isPresented: $isAdding) {
            DictionaryEditor(entry: nil) { store.add($0) }
        }
        .sheet(item: $editing) { entry in
            DictionaryEditor(entry: entry) { store.update($0) }
        }
    }

    /// Both of these are stages rather than faults, which is why neither is a grey symbol
    /// any more: an empty dictionary is one nobody has taught anything to *yet*, and a
    /// search that found nothing is the app having looked. The orbs are the ones the
    /// vocabulary already assigns to those two causes.
    @ViewBuilder
    private var emptyState: some View {
        if store.entries.isEmpty {
            OrbUnavailableView(
                .breathing,
                title: "Dictionary empty",
                message: "Add words it keeps getting wrong."
            )
        } else {
            OrbUnavailableView(
                .searching,
                title: "No results",
                message: "Nothing in the dictionary matches \u{201C}\(query)\u{201D}."
            )
        }
    }

    /// The file path is shown because the spec asks for the dictionary to be editable
    /// outside the UI — which is only true if you can find it.
    ///
    /// This band is the only chrome the screen has, so it is where the field goes: a list
    /// paints an opaque background over anything laid behind it, and a texture nobody can
    /// see is a texture that should not be drawn. Heaviest at the bottom edge, so the
    /// window ends on a ground rather than on a hairline.
    private var footer: some View {
        HStack {
            // The count is set as the page sets a card label — small, letterspaced, upper
            // case — rather than as another line of body text competing with the link.
            Text("\(store.entries.count) entr\(store.entries.count == 1 ? "y" : "ies")")
                .font(DS.Font.eyebrow)
                .tracking(DS.Font.eyebrowTracking)
                .textCase(.uppercase)
                .foregroundStyle(DS.Color.textSecondary)
            Spacer()
            Button("Reveal dictionary.txt") {
                NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
            }
            .buttonStyle(.link)
            .help(DictionaryStore.fileURL.path)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .dottedField(
            opacity: DS.Opacity.field,
            spacing: DS.Field.spacingTight,
            fade: .bottom
        )
    }
}

// MARK: - Row

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Toggle("Enabled", isOn: Binding(get: { entry.isEnabled }, set: { _ in onToggle() }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help(entry.isEnabled ? "Applied to transcripts" : "Ignored")

            StatusChip(text: entry.kind == .correction ? "Fix" : "Term")
                .frame(width: DS.Size.chipColumn, alignment: .leading)

            if entry.kind == .correction {
                Text(entry.hear)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.textSecondary)
                Image(systemName: "arrow.right")
                    .font(DS.Font.caption2)
                    .foregroundStyle(DS.Color.textTertiary)
            }

            Text(entry.write)
                .font(DS.Font.body)

            Spacer()
        }
        .opacity(entry.isEnabled ? 1 : DS.Opacity.disabled)
        .padding(.vertical, DS.Space.xxs)
    }
}

// MARK: - Editor

/// Add or edit one entry, with the false-positive warning shown live as you type.
private struct DictionaryEditor: View {
    let entry: DictionaryEntry?
    let onSave: (DictionaryEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: DictionaryEntry.Kind
    @State private var hear: String
    @State private var write: String

    init(entry: DictionaryEntry?, onSave: @escaping (DictionaryEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _kind = State(initialValue: entry?.kind ?? .term)
        _hear = State(initialValue: entry?.hear ?? "")
        _write = State(initialValue: entry?.write ?? "")
    }

    private var draft: DictionaryEntry {
        DictionaryEntry(
            id: entry?.id ?? UUID(),
            kind: kind,
            write: write.trimmingCharacters(in: .whitespacesAndNewlines),
            hear: kind == .correction ? hear.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            isEnabled: entry?.isEnabled ?? true
        )
    }

    private var warnings: [DictionaryWarning] { DictionaryWarning.check(draft) }

    private var isValid: Bool {
        !draft.write.isEmpty && (kind == .term || !draft.hear.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            SectionHeading(
                title: entry == nil ? "New Entry" : "Edit Entry",
                eyebrow: SidebarSection.dictionary.title
            )

            Form {
                Picker("Kind", selection: $kind) {
                    Text("Term").tag(DictionaryEntry.Kind.term)
                    Text("Correction").tag(DictionaryEntry.Kind.correction)
                }
                .pickerStyle(.segmented)

                if kind == .correction {
                    TextField("When you hear", text: $hear, prompt: Text("cloud code"))
                }
                TextField(
                    kind == .correction ? "Write" : "Word or phrase",
                    text: $write,
                    prompt: Text(kind == .correction ? "Claude Code" : "Anthropic")
                )
            }
            .formStyle(.grouped)
            .animation(DS.Motion.standard, value: kind)

            ForEach(warnings) { warning in
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.sheetWidth)
    }
}
