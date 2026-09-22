import SwiftUI

/// The approval card: exactly what is about to happen, exactly what is missing, and a place
/// to fill it in.
///
/// The card it replaces said two sentences and offered Dismiss and Approve. What it could
/// not say was *what would be passed* — so an email with no recipient, an address the model
/// had never seen, and "Hi [Name]," all looked identical to a message that was ready to go.
/// This one draws the tool's own schema: one row per argument, the value that would be used,
/// and a plain sentence saying where that value came from.
///
/// Approve is bound to `review.isReadyToRun`, which is false while anything is empty, is a
/// stand-in, or was invented — and `PermissionGate.respond` refuses an approval in that
/// state anyway, so the disabled button is the courtesy rather than the enforcement.
struct ToolReviewCard: View {
    let review: ToolCallReview
    /// Compact is the conversation's inline card; the expanded form is a sheet or a pane.
    var isCompact = false
    let approve: () -> Void
    let dismiss: () -> Void
    /// Nil hides the "always allow" affordance, which most surfaces want hidden.
    var alwaysAllow: (() -> Void)?

    @State private var store = ToolCallReviewStore.shared
    @State private var expandedBody: String?
    /// Which field the one-question path is asking about, if any.
    @State private var asking: String?
    @State private var spokenAnswer = ""
    @FocusState private var focusedField: String?

    /// Read back off the store every time: the answer to "Tell me instead" writes there.
    private var live: ToolCallReview { store.review(id: review.id) ?? review }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            header
            if let asking, let field = live.field(asking) {
                question(for: field)
            }
            fields
            footer
        }
        .padding(DS.Space.card)
        .glassSurface()
        .animation(DS.Motion.fluid, value: live.blockers.count)
        .animation(DS.Motion.fluid, value: asking)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(live.title)
                    .font(DS.Font.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let needed = live.needsSummary {
                    Label(needed, systemImage: "exclamationmark.circle.fill")
                        .font(DS.Font.chip)
                        .foregroundStyle(DS.Color.warning)
                }
            }
            Text(live.why)
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(live.title). \(live.why) \(live.needsSummary ?? "")")
    }

    // MARK: - Fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(live.fields) { field in
                row(field)
            }
        }
    }

    @ViewBuilder
    private func row(_ field: ToolCallField) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack(spacing: DS.Space.xs) {
                Text(field.label)
                    .font(DS.Font.sectionLabel)
                if field.isRequired && field.value.isEmpty {
                    Text("needed")
                        .font(DS.Font.chip)
                        .foregroundStyle(DS.Color.warning)
                }
                Spacer(minLength: 0)
                if field.problem == .notConfirmed {
                    Button("That's right") { store.confirm(id: live.id, field: field.name) }
                        .buttonStyle(.borderless)
                        .font(DS.Font.chip)
                }
            }
            editor(for: field)
            // People the app already knows, for a recipient it could not confirm. One
            // click rather than typing an address, and still the user's choice.
            if !field.suggestions.isEmpty {
                FlowLayout(spacing: DS.Space.xs) {
                    ForEach(field.suggestions, id: \.self) { suggestion in
                        Button(suggestion) {
                            store.update(id: live.id, field: field.name, to: suggestion)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            if !field.statusLine.isEmpty {
                Text(field.statusLine)
                    .font(DS.Font.caption)
                    .foregroundStyle(field.needsAnswer ? DS.Color.warning : DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(field.label)
        .accessibilityHint(field.statusLine)
    }

    @ViewBuilder
    private func editor(for field: ToolCallField) -> some View {
        switch field.kind {
        case .longText:
            // A message body is the thing most worth reading and the thing a card has
            // least room for. Collapsed it is three lines; the disclosure gives the
            // whole of it, editable.
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                if expandedBody == field.name {
                    TextEditor(text: binding(field))
                        .font(DS.Font.transcript)
                        .frame(height: DS.Size.messagePreviewHeight)
                        .focused($focusedField, equals: field.name)
                } else {
                    Text(field.value.isEmpty ? field.prompt : field.value)
                        .font(DS.Font.transcript)
                        .foregroundStyle(field.value.isEmpty ? DS.Color.textSecondary : DS.Color.text)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(expandedBody == field.name ? "Done" : "Read and edit\u{2026}") {
                    expandedBody = expandedBody == field.name ? nil : field.name
                    focusedField = expandedBody
                }
                .buttonStyle(.borderless)
                .font(DS.Font.chip)
            }
        case .choice where !field.options.isEmpty:
            Picker(field.label, selection: binding(field)) {
                ForEach(field.options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        default:
            TextField(field.prompt, text: binding(field))
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: field.name)
                .onSubmit { focusNextBlocker(after: field.name) }
        }
    }

    // MARK: - One question at a time

    /// "Tell me instead": the agent asks the single shortest question it needs answered,
    /// and the answer goes straight into the field. Deliberately one question — a card
    /// that asks four things in a row is a form with extra steps.
    private func question(for field: ToolCallField) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Label(field.prompt, systemImage: "quote.bubble")
                .font(DS.Font.callout)
            HStack(spacing: DS.Space.s) {
                TextField("Type or dictate the answer", text: $spokenAnswer)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: "ask")
                    .onSubmit { answer(field) }
                Button("Use this") { answer(field) }
                    .disabled(spokenAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { asking = nil; spokenAnswer = "" }
            }
        }
        .padding(DS.Space.cardTight)
        .background(DS.Color.groupedFill, in: RoundedRectangle(cornerRadius: DS.Radius.glassSmall))
    }

    private func answer(_ field: ToolCallField) {
        let text = spokenAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.update(id: live.id, field: field.name, to: text)
        spokenAnswer = ""
        // Straight on to the next thing that is owed, so a two-blank card is two
        // sentences rather than two visits.
        asking = live.blockers.first?.name
        if asking != nil { focusedField = "ask" }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: DS.Space.s) {
            if !live.isReadyToRun {
                Button("Tell me instead") {
                    asking = live.blockers.first?.name
                    focusedField = "ask"
                }
                .help("The assistant asks one short question and fills this in.")
            }
            Spacer(minLength: 0)
            Button("Dismiss", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if let alwaysAllow, live.isReadyToRun {
                Button("Always allow this", action: alwaysAllow)
            }
            Button(approveTitle) { approve() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!live.isReadyToRun)
                .help(live.isReadyToRun
                      ? "Runs exactly what is on this card."
                      : (live.needsSummary ?? "Something is still needed."))
        }
        .controlSize(isCompact ? .small : .regular)
    }

    /// The button says what it will do. "Approve" is a word about permission; the user is
    /// deciding whether to send an email.
    private var approveTitle: String {
        switch live.toolID {
        case "send_email", "workspace.send_email": "Send it"
        case "reply_email", "workspace.reply_email": "Send the reply"
        case "draft_email", "workspace.draft_email": "Save the draft"
        case "create_event", "workspace.create_event": "Add it to the calendar"
        default: live.wasEdited ? "Run it as edited" : "Go ahead"
        }
    }

    // MARK: - Plumbing

    private func binding(_ field: ToolCallField) -> Binding<String> {
        Binding(
            get: { store.review(id: live.id)?.field(field.name)?.value ?? field.value },
            set: { store.update(id: live.id, field: field.name, to: $0) }
        )
    }

    private func focusNextBlocker(after name: String) {
        guard let next = live.blockers.first(where: { $0.name != name }) else {
            focusedField = nil
            return
        }
        focusedField = next.name
    }
}

/// The read-only half of the card: exactly what would be passed, and what is still owed.
///
/// Used where the editing already lives somewhere else — a meeting's proposal has its own
/// sheet — so that the row in front of the user still says "no address yet" rather than
/// looking finished until they open it.
struct ToolReviewSummary: View {
    let review: ToolCallReview
    /// Long bodies are shown elsewhere on those cards; this leaves them out by default.
    var includesLongText = false
    /// "That's right" for a value the app could not confirm. Without it a summary is a
    /// dead end: a real address that was never said out loud can be typed into the editing
    /// sheet and still come back unconfirmed, and there is nothing on the row that lets the
    /// person who knows it say so. Nil leaves the affordance out for surfaces with no way
    /// to record the answer.
    var confirm: ((String) -> Void)?

    private var rows: [ToolCallField] {
        review.fields.filter { field in
            guard includesLongText || field.kind != .longText else { return false }
            return field.needsAnswer || !field.value.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            if let needed = review.needsSummary {
                Label(needed, systemImage: "exclamationmark.circle.fill")
                    .font(DS.Font.chip)
                    .foregroundStyle(DS.Color.warning)
            }
            ForEach(rows) { field in
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                    Text(field.label)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                        .frame(width: DS.Size.trackLabelWidth * 2, alignment: .leading)
                    if field.needsAnswer {
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            if !field.value.isEmpty {
                                Text(field.shortValue)
                                    .font(DS.Font.caption)
                                    .textSelection(.enabled)
                            }
                            Text(field.statusLine)
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(field.shortValue)
                            .font(DS.Font.caption)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    if let confirm, field.problem == .notConfirmed {
                        Button("That\u{2019}s right") { confirm(field.name) }
                            .buttonStyle(.borderless)
                            .font(DS.Font.chip)
                            .help("Records that you know this value is right.")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(field.label): \(field.needsAnswer ? field.statusLine : field.value)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
