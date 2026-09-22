import SwiftUI

/// Edit exactly what a proposal would run, before approving it.
///
/// The reason this exists rather than an Approve/Dismiss pair: a local 4B model gets the
/// intent right far more often than the wording, and "almost the right email" should be a
/// twenty-second edit rather than a dismissal. The fields are the tool's own parameters, so
/// what is on screen is what reaches the command line.
struct ProposalArgumentsSheet: View {
    let proposal: AgentProposal
    let save: ([String: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Seeded from the proposal, so arguments the catalogue no longer names survive a save
    /// rather than being silently dropped.
    @State private var values: [String: String]

    init(proposal: AgentProposal, save: @escaping ([String: String]) -> Void) {
        self.proposal = proposal
        self.save = save
        _values = State(initialValue: proposal.arguments)
    }

    private var parameters: [WorkspaceTool.Parameter] { proposal.definition?.parameters ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            // The tool's own name reads as an eyebrow rather than as a footnote: it is the
            // category this sheet belongs to, which is exactly what an eyebrow is for. The
            // orb is `searching` and still — the pass that produced this proposal is over,
            // and the sheet is only editing what it came back with.
            SectionHeading(
                title: proposal.title,
                eyebrow: proposal.tool,
                orb: .searching
            )

            Form {
                ForEach(parameters) { parameter in
                    field(for: parameter)
                }
            }
            .formStyle(.grouped)

            HStack(alignment: .firstTextBaseline) {
                if let problem {
                    Text(problem)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    save(values)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isComplete)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.sheetWidth)
    }

    @ViewBuilder
    private func field(for parameter: WorkspaceTool.Parameter) -> some View {
        switch parameter.kind {
        case .multiline:
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                // The label a person can read. `document_id` is a schema key, and a sheet
                // that prints it has asked somebody to approve a word they do not know.
                Text(label(parameter))
                    .font(DS.Font.sectionLabel)
                TextEditor(text: binding(parameter.name))
                    .font(DS.Font.transcript)
                    .frame(height: DS.Size.messagePreviewHeight)
                Text(parameter.description)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        case .text, .list, .date:
            LabeledContent(label(parameter)) {
                VStack(alignment: .trailing, spacing: DS.Space.xxs) {
                    TextField(parameter.description, text: binding(parameter.name))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: DS.Size.settingsFieldWidth)
                    Text(parameter.description)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                        .frame(width: DS.Size.settingsFieldWidth, alignment: .leading)
                }
            }
        }
    }

    /// Every required field has something real in it. A proposal saved with a blank
    /// recipient would fail the moment it was approved, which is a worse place to learn
    /// about it — and one saved with "[Name]" would not fail at all, which is worse again.
    private var isComplete: Bool { problem == nil }

    /// The sentence shown under the buttons when Save is off, so the greyed button is not
    /// a puzzle. Nil when everything is answered.
    private var problem: String? {
        guard let definition = proposal.definition else { return nil }
        return ToolCallValidation.problem(
            tool: AgentTool.workspace(definition), arguments: values)
    }

    private func label(_ parameter: WorkspaceTool.Parameter) -> String {
        ToolCallReviewBuilder.label(for: parameter.name, toolID: proposal.tool)
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(
            get: { values[name] ?? "" },
            set: { values[name] = $0 }
        )
    }
}
