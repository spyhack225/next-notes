import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Bring memory in": pick a file or another assistant, look at every line, keep what you want.
///
/// The review step is not a courtesy. Imported text is somebody else's writing arriving in
/// the place the Agent reads before it answers, so nothing is saved until a person has seen
/// it — and the lines that were thrown out are shown too, because "it silently dropped
/// three things" is the one outcome worse than showing them.
struct MemoryImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var controller = MemoryPortabilityController()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            header

            switch controller.stage {
            case .start: StartStep(controller: controller)
            case .paste: PasteStep(controller: controller)
            case .working(let note): WorkingStep(note: note)
            case .restore: RestoreStep(controller: controller)
            case .review: ReviewStep(controller: controller)
            case .done: DoneStep(controller: controller) { dismiss() }
            }

            if let error = controller.error {
                Text(error)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(DS.Space.page)
        .frame(width: DS.Size.memoryPortabilitySheetWidth,
               height: DS.Size.memoryPortabilitySheetHeight)
    }

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Text(MemoryDataControls.importTitle)
                .font(DS.Font.headline)
            Spacer()
            if controller.stage != .start, controller.stage != .done {
                Button("Start over") { controller.reset() }
                    .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if controller.stage == .start {
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}

// MARK: - Step 1: where from

private struct StartStep: View {
    let controller: MemoryPortabilityController
    @State private var showingAssistants = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Text("Memories your assistant already has stay where they are. Anything you "
                 + "bring in is added to them, and you see every line first.")
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            choice(title: "From a file on this Mac",
                   detail: "A memory folder saved from Next Notes, or anything you "
                       + "downloaded from another assistant.",
                   symbol: "folder") { pickFile() }

            choice(title: "From another assistant",
                   detail: "Muse, Grok, ChatGPT, Claude, Gemini — ask it what it remembers "
                       + "about you and paste the answer here.",
                   symbol: "bubble.left.and.bubble.right") { showingAssistants = true }

            if showingAssistants {
                FlowLayout(spacing: DS.Space.s) {
                    ForEach(MemoryImportSource.allCases) { source in
                        Button(source.displayName) { controller.choosePaste(source) }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func choice(title: String, detail: String, symbol: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                Image(systemName: symbol)
                    .font(DS.Font.title3)
                    .foregroundStyle(DS.Color.textSecondary)
                    .frame(width: DS.Size.appIcon)
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(title)
                        .font(DS.Font.body.weight(.medium))
                        .foregroundStyle(DS.Color.text)
                    Text(detail)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(DS.Space.card)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: DS.Radius.glassSmall)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a memory file or folder"
        panel.prompt = "Read"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = MemoryImportSheet.readableTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.read(fileAt: url)
    }
}

extension MemoryImportSheet {
    /// What the open panel will let through. A folder is always selectable, so a Next Notes
    /// memory folder works whether the person picks the folder or the file inside it.
    static let readableTypes: [UTType] = [
        .json, .plainText, .commaSeparatedText, .html, .zip, .folder,
        UTType(filenameExtension: "md") ?? .plainText,
    ]
}

// MARK: - Step 2: the guided paste

private struct PasteStep: View {
    @Bindable var controller: MemoryPortabilityController
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Bringing memory in from \(controller.source.displayName)")
                .font(DS.Font.body.weight(.medium))

            step(1, controller.source.openingStep)
            step(2, "Copy this message and send it there.")

            HStack(alignment: .top, spacing: DS.Space.s) {
                Text(MemoryImportPrompt.text)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MemoryImportPrompt.text, forType: .string)
                    copied = true
                }
                .buttonStyle(.bordered)
            }
            .padding(DS.Space.cardTight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: DS.Radius.glassSmall)

            step(3, "Paste its answer below.")

            TextEditor(text: $controller.pastedText)
                .font(DS.Font.body)
                .frame(height: DS.Size.memoryPasteBoxHeight)

            if let note = controller.source.fileNote {
                SettingsNote(text: note)
            }

            HStack {
                Button("Back") { controller.reset() }
                Spacer()
                Button("Read it") { controller.readPastedText() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(controller.pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Text("\(number)")
                .font(DS.Font.caption.monospacedDigit())
                .foregroundStyle(DS.Color.textSecondary)
                .frame(width: DS.Space.l, alignment: .trailing)
            Text(text)
                .font(DS.Font.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Working

private struct WorkingStep: View {
    let note: String

    var body: some View {
        VStack(spacing: DS.Space.l) {
            Spacer()
            // `searching` — reading things it did not write, to find something. Which is
            // exactly what this is doing to somebody else's notes.
            ThinkingOrb(state: .searching, size: DS.Size.orbMedium)
                .accessibilityHidden(true)
            Text(note)
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Step 3a: one of our own files

private struct RestoreStep: View {
    @Bindable var controller: MemoryPortabilityController
    @State private var confirmingReplace = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            if let note = controller.content?.note {
                Text(note)
                    .font(DS.Font.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("", selection: $controller.restoreMode) {
                Text("Add to what's here").tag(NextMemory.RestoreMode.merge)
                Text("Replace everything").tag(NextMemory.RestoreMode.replace)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text(controller.restoreMode == .merge
                 ? "The memories in the file are added beside the ones your assistant already "
                    + "has. Nothing is lost."
                 : "Everything your assistant remembers now is thrown away and replaced by what "
                    + "is in the file. A copy of the \(controller.currentMemoryCount) it has now "
                    + "is saved first, so you can bring them back.")
                .font(DS.Font.caption)
                .foregroundStyle(controller.restoreMode == .replace
                                 ? DS.Color.warning : DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if controller.restoreMode == .replace {
                Toggle("Also put back its name, face and soul",
                       isOn: $controller.restoreIdentityAndSoul)
            }

            HStack {
                Button("Back") { controller.reset() }
                Spacer()
                // Replacing throws away every memory and its whole history, so it asks —
                // the same way "Forget everything" does two panes away — and it is not on
                // Return, because Return is how a person gets through a sheet without
                // reading it.
                Button(controller.restoreMode == .merge ? "Add them" : "Replace everything") {
                    if controller.restoreMode == .replace {
                        confirmingReplace = true
                    } else {
                        controller.restorePackage()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(controller.restoreMode == .merge ? .defaultAction : nil)
                .confirmationDialog(
                    controller.currentMemoryCount == 1
                        ? "Throw away the 1 memory your assistant has now?"
                        : "Throw away the \(controller.currentMemoryCount) memories your assistant has now?",
                    isPresented: $confirmingReplace) {
                        Button("Replace everything", role: .destructive) {
                            controller.restorePackage()
                        }
                    } message: {
                        Text("Its notes, and everything it has learned since, are replaced by "
                             + "what is in the file. A copy is saved in the Next Notes folder "
                             + "first, so you can bring them back.")
                    }
            }
        }
    }
}

// MARK: - Step 3b: the review list

private struct ReviewStep: View {
    @Bindable var controller: MemoryPortabilityController
    @State private var memory = NextMemory.shared

    private var plan: MemoryImportPlan { controller.plan }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            summary

            if plan.isEmpty, plan.dropped.isEmpty {
                OrbUnavailableView(state: .searching,
                                   title: "Nothing to keep",
                                   message: "There was no fact in what you gave it.",
                                   hasField: false) { EmptyView() }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        ForEach($controller.plan.proposals) { $proposal in
                            ProposalRow(proposal: $proposal)
                        }
                        if !plan.dropped.isEmpty { droppedSection }
                    }
                    .padding(.trailing, DS.Space.s)
                }
                .frame(height: DS.Size.memoryReviewListHeight)
            }

            budget

            HStack {
                Button("Back") { controller.reset() }
                Spacer()
                Button("Keep \(plan.selected.count) " + (plan.selected.count == 1 ? "memory" : "memories")) {
                    controller.saveReviewed()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(plan.selected.isEmpty)
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(headline)
                .font(DS.Font.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let note = plan.note {
                Text(note)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var headline: String {
        var parts = ["Found \(plan.proposals.count) "
                     + (plan.proposals.count == 1 ? "memory" : "memories")
                     + " in \(plan.origin)."]
        if plan.duplicateCount > 0 {
            parts.append("\(plan.duplicateCount) "
                         + (plan.duplicateCount == 1 ? "is" : "are")
                         + " already known, so "
                         + (plan.duplicateCount == 1 ? "it is" : "they are")
                         + " unticked.")
        }
        parts.append("Edit anything that reads wrong, then keep what you want.")
        return parts.joined(separator: " ")
    }

    private var droppedSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Divider()
                .padding(.vertical, DS.Space.xs)
            Text("Left out (\(plan.dropped.count))")
                .font(DS.Font.caption.weight(.medium))
                .foregroundStyle(DS.Color.textSecondary)
            ForEach(plan.dropped) { item in
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(item.text)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textTertiary)
                        .strikethrough()
                        .lineLimit(2)
                    Text(item.reason)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.warning)
                }
            }
        }
    }

    /// What the ticked facts would do to the two budgets. Shown before saving, because a
    /// budget refusal after the fact reads as a bug.
    @ViewBuilder
    private var budget: some View {
        let over = MemoryEntry.Kind.allCases.filter {
            memory.used($0) + plan.selectedCharacters($0) > $0.budget
        }
        if !over.isEmpty {
            SettingsNote(text: "That is more than “"
                         + over.map(\.displayName).joined(separator: "” and “")
                         + "” can hold. The ones that don't fit will be listed rather than "
                         + "kept — untick a few, or forget some old ones first.")
        }
    }
}

private struct ProposalRow: View {
    @Binding var proposal: ProposedMemory

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Toggle("", isOn: $proposal.isSelected)
                .labelsHidden()
                .accessibilityLabel("Keep this memory")

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                TextField("Memory", text: $proposal.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)

                HStack(spacing: DS.Space.s) {
                    Picker("", selection: $proposal.kind) {
                        ForEach(MemoryEntry.Kind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    if let duplicate = proposal.duplicateOf {
                        Text("Already known: “\(duplicate)”")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                            .lineLimit(1)
                    } else if proposal.isEdited {
                        Text("Edited")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                    }
                }
            }
        }
        .padding(DS.Space.cardTight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.glassSmall)
        .opacity(proposal.isSelected ? 1 : DS.Opacity.disabled)
    }
}

// MARK: - Step 4: the receipt

private struct DoneStep: View {
    let controller: MemoryPortabilityController
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            if let receipt = controller.receipt {
                Text(sentence(receipt))
                    .font(DS.Font.callout)
                    .fixedSize(horizontal: false, vertical: true)

                if !receipt.notSaved.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("Not kept")
                            .font(DS.Font.caption.weight(.medium))
                            .foregroundStyle(DS.Color.textSecondary)
                        ForEach(Array(receipt.notSaved.enumerated()), id: \.offset) { _, item in
                            Text(item.text.isEmpty ? item.reason : "“\(item.text)” — \(item.reason)")
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                SettingsNote(text: note(receipt))
            }

            HStack {
                if controller.undoableCount > 0 {
                    Button("Undo this import", role: .destructive) { controller.undo() }
                } else if let backup = controller.backupFolder {
                    // A replace has no Undo, so the way back is the copy it wrote first.
                    Button("Show the old memories") {
                        NSWorkspace.shared.activateFileViewerSelecting([backup])
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Where they went, and when the assistant starts using them — which is now, because a
    /// change the person made themselves re-freezes the prompt snapshot straight away.
    private func note(_ receipt: NextMemory.ImportReceipt) -> String {
        let where_ = receipt.saved.contains(where: { $0.importedFrom != nil })
            ? "They're in the memory list now, each marked “Imported from "
                + "\(controller.plan.origin)”."
            : "They're in the memory list now, with the dates and labels they had before."
        let backup = controller.backupFolder == nil ? ""
            : " The memories it had before this are saved in a folder called "
                + "“\(MemoryPortabilityController.backupFolderName)”, in case you want them back."
        return where_ + " Your assistant uses them from its next answer." + backup
    }

    private func sentence(_ receipt: NextMemory.ImportReceipt) -> String {
        var parts: [String] = []
        if receipt.saved.isEmpty {
            parts.append("Nothing new was kept.")
        } else {
            parts.append("Kept \(receipt.saved.count) "
                         + (receipt.saved.count == 1 ? "memory" : "memories") + ".")
        }
        if !receipt.alreadyKnown.isEmpty {
            parts.append("\(receipt.alreadyKnown.count) "
                         + (receipt.alreadyKnown.count == 1 ? "was" : "were")
                         + " already remembered word for word.")
        }
        return parts.joined(separator: " ")
    }
}
