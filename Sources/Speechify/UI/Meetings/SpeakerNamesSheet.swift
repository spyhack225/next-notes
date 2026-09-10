import SwiftUI

/// Puts real names on the labels diarization produced.
///
/// The model can tell one voice from another; it cannot know whose voice it is. Only the
/// person who was in the meeting can, which is why this is a text field rather than a
/// guess — and why the invite's attendee list is offered beside it, since on a calendar
/// meeting the names are usually already known, just not attached to anyone.
///
/// Renaming rewrites nothing: `Meeting.speakerNames` maps the generated label to a display
/// name, and the transcript keeps the label. That way a second diarization pass, or a
/// rename the user regrets, changes one small dictionary instead of every segment.
struct SpeakerNamesSheet: View {
    let labels: [String]
    let suggestions: [String]
    let initialNames: [String: String]
    let onSave: ([String: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var names: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            // `solving` is diarization's shape everywhere else in the app, and this sheet is
            // what diarization was for — so the same mark opens it. Still: the clustering
            // pass has already finished by the time anyone can be renamed.
            SectionHeading(
                title: "Who was speaking?",
                eyebrow: "Speakers",
                subtitle: "Leave a field empty to keep the label the model gave it. The notes "
                    + "use these names the next time they are written.",
                orb: .solving
            )

            Form {
                ForEach(labels, id: \.self) { label in
                    LabeledContent {
                        TextField(
                            label,
                            text: binding(for: label),
                            prompt: Text(label)
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: DS.Size.settingsFieldWidth)
                    } label: {
                        SpeakerLabel(name: label, color: DS.Color.speaker(named: label))
                    }
                }
            }
            .formStyle(.grouped)

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("On the invite")
                        .font(DS.Font.sectionLabel)
                        .foregroundStyle(DS.Color.textSecondary)
                    FlowLayout(spacing: DS.Space.xs) {
                        ForEach(suggestions, id: \.self) { attendee in
                            StatusChip(text: attendee, systemImage: "person")
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    onSave(cleaned)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.sheetWidth)
        .onAppear { names = initialNames }
    }

    private func binding(for label: String) -> Binding<String> {
        Binding(
            get: { names[label] ?? "" },
            set: { names[label] = $0 }
        )
    }

    /// An emptied field means "no name", not "a person called nothing".
    private var cleaned: [String: String] {
        names.compactMapValues { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
