import NextNotesDictionary
import SwiftUI

/// One past dictation in the list.
///
/// The Copy button appears on hover only. A visible button on every row turns a list of
/// sentences into a list of controls, and the same command is on the context menu for
/// anyone who never hovers.
///
/// **No orb lives here.** Every orb is a `Canvas` in a `TimelineView`, and a mark on each
/// row is one per visible row — a scattering of small ones is exactly what the vocabulary
/// forbids, and a list scrolls. The row speaks the same language through its type instead:
/// the engine is set as the landing page sets a card label, and everything above the
/// sentence is quieted so the sentence is what the eye lands on.
struct TranscriptionRow: View {
    let run: DictationRun

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var draft = ""
    /// Corrections this edit implies, awaiting a yes. Empty when nothing was learned or the
    /// user has asked for them to be filed without asking.
    @State private var proposed: [LearnedCorrection] = []
    @State private var chosen: Set<String> = []
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                // An eyebrow rather than a chip. A filled badge on every row turned a list
                // of sentences into a list of badges, and the engine is context for the
                // transcript rather than a status about it.
                Text(run.engine)
                    .font(DS.Font.eyebrow)
                    .tracking(DS.Font.eyebrowTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(DS.Color.textSecondary)
                Text(run.date, style: .time)
                    .font(DS.Font.timestamp)
                    .foregroundStyle(DS.Color.textSecondary)
                Text("\(run.processSeconds, format: .number.precision(.fractionLength(2)))s")
                    .font(DS.Font.timestamp)
                    .foregroundStyle(DS.Color.textTertiary)
                Spacer()
                if run.wasEdited {
                    // Says the sentence below is yours, not the model's — and so explains
                    // why it may not match what the engine actually produced.
                    Image(systemName: "pencil")
                        .font(DS.Font.caption2)
                        .foregroundStyle(DS.Color.textTertiary)
                        .help("You corrected this transcript")
                }
                Button {
                    draft = run.displayText
                    isEditing = true
                    editorFocused = true
                } label: {
                    Label("Correct", systemImage: "pencil")
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .opacity(isHovering && !isEditing ? 1 : 0)
                .help("Correct this transcript, and teach the dictionary")

                CopyButton(text: run.displayText, title: "Copy")
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .opacity(isHovering ? 1 : 0)
            }

            // Deliberately NOT `.textSelection(.enabled)`. In a selectable `List` the two
            // compete for the same mouse-down: selectable text takes the click to place a
            // caret, so clicking the body of a row would not select the row — and the body
            // is most of the row's area. Selecting a fragment is the rarer want; Copy is on
            // hover and in the context menu, for one row or for many. If free selection is
            // ever wanted back, it belongs in a detail view, not in the list.
            //
            // Capped at a comfortable measure rather than at the window's. A detail pane on
            // a wide display is far wider than a readable line, and nothing about the
            // window's width is an argument for a 1400pt one. The row itself still runs the
            // full width — the `Spacer()` above and `.contentShape` below see to that — so
            // clicking beside the text still selects the row.
            if isEditing {
                // A plain `TextField` with `.vertical` axis rather than a `TextEditor`: the
                // editor brings its own scroll view and background into a list row that
                // already has both, and a transcript is a sentence or two.
                TextField("Transcript", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DS.Font.transcript)
                    .focused($editorFocused)
                    .frame(maxWidth: DS.Size.readingWidth, alignment: .leading)
                    .onSubmit(commit)
                HStack(spacing: DS.Space.s) {
                    Button("Save", action: commit)
                        .keyboardShortcut(.defaultAction)
                    Button("Cancel") { isEditing = false }
                        .keyboardShortcut(.cancelAction)
                }
                .font(DS.Font.caption)
            } else {
                Text(run.displayText)
                    .font(DS.Font.transcript)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: DS.Size.readingWidth, alignment: .leading)
            }

            if let corrections = run.corrections, !corrections.isEmpty {
                CorrectionBadges(corrections: corrections)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DS.Space.s)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .sheet(isPresented: Binding(get: { !proposed.isEmpty }, set: { if !$0 { proposed = [] } })) {
            LearnedCorrectionsSheet(
                corrections: proposed,
                chosen: $chosen,
                onAdd: {
                    for correction in proposed where chosen.contains(correction.id) {
                        DictionaryStore.shared.add(correction.entry)
                    }
                    proposed = []
                },
                onSkip: { proposed = [] }
            )
        }
    }

    /// Saves the edit, then reads the dictionary lesson out of it.
    ///
    /// The save happens first and unconditionally. Learning is the bonus; a correction the
    /// user typed is worth keeping even when nothing general can be inferred from it.
    private func commit() {
        let edited = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
        guard !edited.isEmpty, edited != run.displayText else { return }

        var updated = run
        updated.editedText = edited
        RunLog.update(updated)

        // Diffed against the transcript as originally written, not against the previous
        // edit: what the engine produced is the thing a dictionary rule has to fire on.
        let candidates = CorrectionLearner.candidates(from: run.text, to: edited)
        guard !candidates.isEmpty else { return }

        switch Settings.shared.dictionaryLearning {
        case .off:
            break
        case .automatic:
            for candidate in candidates { DictionaryStore.shared.add(candidate.entry) }
        case .ask:
            chosen = Set(candidates.map(\.id))
            proposed = candidates
        }
    }
}

/// What the edit taught, and a chance to disagree with it.
///
/// Every row is pre-ticked. The edit is evidence the user already produced deliberately, so
/// the default is to believe it — this exists to catch the case where a rewrite happened to
/// look like a correction, not to make the user re-approve their own typing.
struct LearnedCorrectionsSheet: View {
    let corrections: [LearnedCorrection]
    @Binding var chosen: Set<String>
    let onAdd: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(corrections.count == 1 ? "Learn this correction?" : "Learn these corrections?")
                    .font(DS.Font.title3)
                Text("Next time it hears the words on the left, it will write the ones on "
                     + "the right — in every app.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(corrections) { correction in
                Toggle(isOn: Binding(
                    get: { chosen.contains(correction.id) },
                    set: { keep in
                        if keep { chosen.insert(correction.id) } else { chosen.remove(correction.id) }
                    }
                )) {
                    HStack(spacing: DS.Space.xs) {
                        Text(correction.hear).foregroundStyle(DS.Color.textSecondary)
                        Image(systemName: "arrow.right")
                            .font(DS.Font.caption2)
                            .foregroundStyle(DS.Color.textTertiary)
                        Text(correction.write)
                    }
                    .font(DS.Font.body)
                }
            }

            HStack {
                Spacer()
                Button("Not now", action: onSkip)
                    .keyboardShortcut(.cancelAction)
                Button("Add to Dictionary", action: onAdd)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(DS.Space.l)
        .frame(minWidth: 380)
    }
}

/// Shows that the dictionary fired, and on what. Without this the dictionary is invisible
/// and you can't tell a rule that works from one that never matches.
struct CorrectionBadges: View {
    let corrections: [AppliedCorrection]

    var body: some View {
        HStack(spacing: DS.Space.s) {
            StatusChip(
                text: "Corrected",
                color: DS.Color.accent,
                systemImage: "character.book.closed"
            )
            ForEach(corrections, id: \.self) { correction in
                HStack(spacing: DS.Space.xs) {
                    Text(correction.from)
                        .strikethrough()
                        .foregroundStyle(DS.Color.textTertiary)
                    Image(systemName: "arrow.right")
                        .font(DS.Font.caption2)
                        .foregroundStyle(DS.Color.textTertiary)
                    Text(correction.to)
                        .foregroundStyle(DS.Color.textSecondary)
                    if correction.count > 1 {
                        Text("×\(correction.count)")
                            .foregroundStyle(DS.Color.textTertiary)
                    }
                }
                .font(DS.Font.caption)
            }
            Spacer()
        }
    }
}
