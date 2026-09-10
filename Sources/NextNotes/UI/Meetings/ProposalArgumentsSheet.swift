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

            HStack {
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
                Text(parameter.name)
                    .font(DS.Font.sectionLabel)
                TextEditor(text: binding(parameter.name))
                    .font(DS.Font.transcript)
                    .frame(height: DS.Size.messagePreviewHeight)
                Text(parameter.description)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        case .text, .list, .date:
            LabeledContent(parameter.name) {
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

    /// Every required field has something in it. A proposal saved with a blank recipient
    /// would fail the moment it was approved, which is a worse place to learn about it.
    private var isComplete: Bool {
        parameters.filter(\.isRequired).allSatisfy { parameter in
            !(values[parameter.name] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(
            get: { values[name] ?? "" },
            set: { values[name] = $0 }
        )
    }
}
